# Self-Hosted GitHub Runner on AWS - Deployment Runbook

Auto-scaling persistent GitHub Actions runners on AWS EC2 Spot, managed by `modules/multi-runner` to support multiple architectures (arm64 + amd64) under a single GitHub App webhook.

## Prerequisites

- AWS CLI configured with admin access
- [Packer](https://developer.hashicorp.com/packer/install) installed
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5 installed
- Existing VPC with private subnets and NAT Gateway

## Step 1: Create GitHub App

1. `https://github.com/settings/apps/new`
2. Permissions: Actions (read), Administration (read/write), Checks (read), Metadata (read)
3. Webhook (Active), placeholder URL: `https://example.com/webhook`
4. Subscribe to **Workflow job** event (appears after Administration permission is set)
5. Create, note **App ID**, generate **private key** (.pem)
6. Install App to your repos

## Step 2: Create Terraform Backend

```bash
export TF_STATE_BUCKET="<your-bucket-name>"
# Optional: enables DynamoDB state locking. Default deployment uses pure
# S3 with no concurrency protection — see CLAUDE.md "State Locking 现状".
# export TF_STATE_LOCK_TABLE="<your-table-name>"
./scripts/01-create-tf-backend.sh
```

## Step 3: Break-Glass AMI Build

Normal AMI builds are scheduled through GitHub Actions as described below.
For an operator-only build that does not enter the managed release channels:

```bash
cd deployments/shared-runners
config="$(terraform output -json ami_release_configuration)"
export AMI_BUILDER_INSTANCE_PROFILE="$(jq -r '.builder_instance_profile_name' <<<"$config")"
export AMI_BUILDER_SECURITY_GROUP_ID="$(jq -r '.builder_security_group_id' <<<"$config")"
export AMI_SUBNET_ID="$(jq -r '.subnet_id' <<<"$config")"
export AMI_SOURCE_OWNER_ID="<aws-account-id>" # Canonical's published account ID.

ARCH=arm64 ./scripts/02-build-ami.sh
ARCH=amd64 ./scripts/02-build-ami.sh
```

Each AMI includes: Node.js 24, Bun, Playwright Chromium, Docker CE, AWS CLI v2, GitHub Actions runner. The amd64 AMI also includes Google Chrome Stable. IMDSv2 is enforced; the latest apt patches are applied at build time.

## Step 4: Deploy Infrastructure

```bash
export GITHUB_APP_ID="<app-id>"
export GITHUB_APP_KEY_BASE64=$(base64 -w 0 < path/to/app.pem)
export VPC_ID="<your-vpc-id>"
export SUBNET_IDS='["<subnet-1>","<subnet-2>"]'
export TF_STATE_BUCKET="<your-bucket-name>"
./scripts/03-deploy.sh
```

## Step 5: Configure GitHub App Webhook

```bash
terraform output webhook_endpoint  # → set as Webhook URL
terraform output -raw webhook_secret  # → set as Webhook secret
```

## Step 6: Configure AMI Release Workflows

After the first Terraform apply, configure the workflow repository secrets
from the `ami_release_configuration` output. These are environment-specific
values and must not be committed:

```bash
config="$(terraform output -json ami_release_configuration)"
repository="<owner>/<repo>"
export AMI_SOURCE_OWNER_ID="<aws-account-id>" # Canonical's published account ID.

gh secret set AMI_BUILD_ROLE_ARN --repo "$repository" \
  --body "$(jq -r '.build_role_arn' <<<"$config")"
gh secret set AMI_PROMOTION_ROLE_AMD64_ARN --repo "$repository" \
  --body "$(jq -r '.promotion_role_arns.amd64' <<<"$config")"
gh secret set AMI_PROMOTION_ROLE_ARM64_ARN --repo "$repository" \
  --body "$(jq -r '.promotion_role_arns.arm64' <<<"$config")"
gh secret set AMI_BUILDER_INSTANCE_PROFILE --repo "$repository" \
  --body "$(jq -r '.builder_instance_profile_name' <<<"$config")"
gh secret set AMI_VALIDATOR_INSTANCE_PROFILE --repo "$repository" \
  --body "$(jq -r '.validator_instance_profile_name' <<<"$config")"
gh secret set AMI_BUILDER_SECURITY_GROUP_ID --repo "$repository" \
  --body "$(jq -r '.builder_security_group_id' <<<"$config")"
gh secret set AMI_VALIDATOR_SECURITY_GROUP_ID --repo "$repository" \
  --body "$(jq -r '.validator_security_group_id' <<<"$config")"
gh secret set AMI_SUBNET_ID --repo "$repository" \
  --body "$(jq -r '.subnet_id' <<<"$config")"
gh secret set AMI_SOURCE_OWNER_ID --repo "$repository" \
  --body "$AMI_SOURCE_OWNER_ID"

# Remove legacy plaintext variables after their secret replacements exist.
legacy_variables="$(gh variable list --repo "$repository" --json name --jq '.[].name')"
for name in \
  AMI_BUILD_ROLE_ARN \
  AMI_PROMOTION_ROLE_AMD64_ARN \
  AMI_PROMOTION_ROLE_ARM64_ARN \
  AMI_BUILDER_INSTANCE_PROFILE \
  AMI_VALIDATOR_INSTANCE_PROFILE \
  AMI_BUILDER_SECURITY_GROUP_ID \
  AMI_VALIDATOR_SECURITY_GROUP_ID \
  AMI_SUBNET_ID \
  AMI_SOURCE_OWNER_ID; do
  if grep -Fxq "$name" <<<"$legacy_variables"; then
    gh variable delete "$name" --repo "$repository"
  fi
done

gh variable set AMI_AUTO_PROMOTE_AMD64 --repo "$repository" --body false
gh variable set AMI_AUTO_PROMOTE_ARM64 --repo "$repository" --body false
```

Create environments `runner-ami-production-amd64` and
`runner-ami-production-arm64`. Restrict both to the default branch and require
reviewers during the initial rollout. The IAM roles trust these exact
environment subjects. Before the first promotion or rollback, verify both
environment settings in the repository and confirm that each has at least one
required reviewer. A workflow reference can create an environment without the
intended protection rules, so the environment name alone is not sufficient.

### Build triggers

`.github/workflows/ami-release.yml` is the only normal build scheduler:

- Schedule: every Monday at `02:37 UTC` (`37 2 * * 1`).
- Scheduled runs build amd64 and arm64 independently.
- Manual dispatch accepts `all`, `amd64`, or `arm64`.
- Build concurrency is per architecture, with at most one running and one
  pending build in each group. A newer duplicate dispatch can replace the
  pending build; an amd64 build never blocks an arm64 build.
- A failure in one architecture does not cancel the other.

Manual examples:

```bash
gh workflow run ami-release.yml --ref "<default-branch>" -f architecture=all
gh workflow run ami-release.yml --ref "<default-branch>" -f architecture=amd64
gh workflow run ami-release.yml --ref "<default-branch>" -f architecture=arm64
```

Each build selects the latest Canonical Ubuntu 26.04 base AMI and the current
package versions available at build time. Packer connects to a private builder
through Session Manager. A separate On-Demand instance boots the final AMI and
validates the toolchain before the AMI receives
`ghr:validation_status=passed`.

### Promotion and rollback

Automatic promotion is disabled independently for both architectures until
the rollout gates below are complete. Promote a passed build by its exact
GitHub run ID and attempt:

```bash
gh workflow run ami-promote.yml --ref "<default-branch>" \
  -f architecture=amd64 \
  -f build_run_id="<run-id>" \
  -f build_run_attempt="<attempt>"
```

Rollback is one level and leaves `previous` unchanged:

```bash
gh workflow run ami-rollback.yml --ref "<default-branch>" \
  -f architecture=amd64
```

Promotion and rollback share a non-cancelling, per-architecture concurrency
group. Do not update any of the six active, previous or recovery parameters
manually while either workflow is running. Recovery is an internal durable
protection channel, not a release an operator selects. Every channel write is
confirmed through bounded read-back because `aws:ec2:image` updates are
asynchronous. If any channel is unreadable or contains a value outside the
workflow's expected transition, the workflow stops without overwriting that
external state.

### Initial rollout gates

1. Confirm the migration plan contains exact moves for both active parameters,
   creates both previous and both recovery parameters with matching values, and
   has no deletes.
2. Run one manual build for both architectures with both auto-promotion
   variables `false`.
3. Manually promote one architecture and monitor real jobs before promoting
   the other.
4. Record three consecutive successful weekly builds for each architecture.
5. Run representative CI workloads and a rollback drill.
6. Set only that architecture's `AMI_AUTO_PROMOTE_*` variable to `true`, remove
   required reviewers from the matching environment, and retain its
   default-branch restriction. To disable it later, set the variable `false`
   before restoring required reviewers.

### Monitoring a promoted AMI

Check channel and Launch Template convergence without printing values into a
public artifact:

```bash
aws ssm get-parameters --region us-east-1 --names \
  /github-action-runners/gh-runner/linux-amd64/runners/config/ami_id \
  /github-action-runners/gh-runner/linux-amd64/runners/config/ami_previous_id \
  /github-action-runners/gh-runner/linux-arm64/runners/config/ami_id \
  /github-action-runners/gh-runner/linux-arm64/runners/config/ami_previous_id

aws ec2 describe-launch-template-versions --region us-east-1 \
  --launch-template-name gh-runner-linux-amd64-action-runner \
  --versions '$Default' --resolve-alias
```

Already-running runners keep their original AMI. New runners use the promoted
active channel. During the observation window, verify:

- New EC2 runners use the promoted AMI and register with the expected labels.
- Representative amd64 and arm64 jobs complete.
- Lighthouse jobs no longer run the Chrome installer and complete normally.
- Scale-up, runner startup, SSM and workflow logs contain no new errors.

### Seven-day cleanup

The AMI housekeeper protects all six active/previous/recovery channels and both
resolved default Launch Templates. It considers only release-managed,
unreferenced AMIs strictly older than 168 hours.

Keep `ami_housekeeper_dry_run=true` for at least one full weekly cycle. Review
the logged candidate set, then apply:

```bash
terraform plan -var="ami_housekeeper_dry_run=false" ...
terraform apply tfplan
```

Snapshot deletion is explicit and awaited. Shared/in-use snapshots are
retained; other cleanup errors fail the invocation. Candidate AMIs are fully
paginated before deletion starts. If AMI deregistration returns an unknown
result, the housekeeper confirms that the AMI is no longer available before
deleting snapshots and never retries the mutation blindly. Restore dry-run by
setting the variable to `true`.

The initial implementation has no durable deletion journal. If the Lambda
process stops after AMI deregistration is confirmed but before every snapshot
is deleted, a later invocation cannot rediscover those snapshots through the
AMI. Treat orphan snapshot discovery and removal as an operator task until a
journal or tagged snapshot sweep is added.

## Step 7: Update Consumer CI Workflows

Pick the architecture each project needs. Both labels are exact-match — jobs do not cross between fleets.

```yaml
# arm64 (general CI)
runs-on: [self-hosted, linux, arm64]

# amd64 (e.g. building GPU container images)
runs-on: [self-hosted, linux, x64]
```

Or drive selection via repo variable:

```yaml
runs-on: ${{ vars.RUNNER_LABEL && fromJSON(vars.RUNNER_LABEL) || 'ubuntu-latest' }}
```

Set repo variable `RUNNER_LABEL` to `["self-hosted", "linux", "arm64"]` or `["self-hosted", "linux", "x64"]`.

## Fleet Configuration

| Setting | linux-arm64 | linux-amd64 |
|---------|-------------|-------------|
| Instance types | `c8g.2xlarge` | `c7a.4xlarge`, `c7i.4xlarge`, `m7a.4xlarge` |
| Architecture | arm64 (Graviton4) | x86_64 (AMD EPYC preferred) |
| Max runners | 10 | 5 |
| Lifecycle | Spot, persistent | Spot, persistent |
| Allocation strategy | `price-capacity-optimized` | `price-capacity-optimized` |
| Idle timeout | 15 minutes | 15 minutes |
| Webhook delay | 30s | 30s |
| AMI | active arm64 SSM channel | active amd64 SSM channel |
| Root volume | 60 GB encrypted gp3 | 60 GB encrypted gp3 |

## Per-Project Usage Tracking

The fleet is intentionally not partitioned per project — per-project visibility comes from CloudWatch Logs Insights against the webhook lambda log, **not** CloudWatch Metrics. The upstream lambdas don't emit a `repository` dimension on any metric (only on EMF metadata, which can't be aggregated in Metrics Explorer). The webhook lambda does log full repo + job + action + conclusion on every `workflow_job` event, which is enough for usage and cost attribution.

Log group: `/aws/lambda/<prefix>-webhook` (e.g. `gh-runner-webhook`).

Each line includes a nested `github` object with these queryable fields:

| Field | Example | Notes |
|-------|---------|-------|
| `github.repository` | `owner/repo` | identifier |
| `github.action` | `queued` / `in_progress` / `completed` | lifecycle stage |
| `github.name` | `Lint & Test` | workflow job name |
| `github.conclusion` | `success` / `failure` / `skipped` / `cancelled` | only set when `action = completed` |
| `github.workflowJobId` | `74932178063` | unique per job — useful for joining queued + completed events |
| `github.started_at` | ISO 8601 | useful for filtering, but Logs Insights can't math on the string directly |
| `github.completed_at` | ISO 8601 | nullable until `action = completed` |

### Common queries

**Q1 — Event count by repo + action** (broad usage signal):

```sql
fields github.repository as repo, github.action as action
| filter ispresent(github.repository)
| stats count() as events by repo, action
| sort events desc
```

**Q2 — Conclusion breakdown by repo** (CI signal: success/skip/fail rates):

```sql
fields github.repository as repo, github.conclusion as conclusion
| filter github.action = "completed" and ispresent(github.conclusion)
| stats count() as jobs by repo, conclusion
| sort repo, jobs desc
```

A high `skipped` ratio for a repo (e.g. 60%+ of completed jobs) usually means a `paths` filter is too broad — every push fires every job, GitHub-side conditional skip dismisses most of them, but each one still cost a webhook → SQS → lambda round-trip.

**Q3 — Wall-clock job time by repo** (cost attribution proxy):

Logs Insights can't parse `github.started_at` / `github.completed_at` ISO strings directly, so derive duration from `@timestamp` of the queued event vs the completed event for the same `workflowJobId`:

```sql
fields @timestamp, github.repository as repo, github.workflowJobId as job_id
| filter ispresent(job_id) and ispresent(repo)
| stats min(@timestamp) as first_at,
        max(@timestamp) as last_at,
        (max(@timestamp) - min(@timestamp)) / 1000 as wall_sec,
        count() as events
        by repo, job_id
| filter events >= 2
| stats count() as jobs,
        sum(wall_sec) as total_wall_sec,
        avg(wall_sec) as avg_wall_sec,
        max(wall_sec) as max_wall_sec
        by repo
| sort total_wall_sec desc
```

`wall_sec` is GitHub's view of job duration — it includes time spent waiting for a runner to come up. For pure compute time, subtract the queued→in_progress delta (a similar query keyed on `action`).

**Q4 — Top job names by repo** (which workflows dominate):

```sql
fields github.repository as repo, github.name as job_name
| filter github.action = "queued" and ispresent(job_name)
| stats count() as launches by repo, job_name
| sort repo, launches desc
```

### Fleet-level signals

For arm64 vs amd64 split, query the scale-up lambda log groups directly:

```bash
for fleet in arm64 amd64; do
  aws logs start-query --region us-east-1 \
    --log-group-name /aws/lambda/gh-runner-linux-${fleet}-scale-up \
    --start-time $(($(date +%s) - 86400)) --end-time $(date +%s) \
    --query-string 'fields @message
| filter @message like /Created instance/
| stats count() as launches'
done
```

For actual instance type selection (the `price-capacity-optimized` allocator may pick the second/third entry from `instance_types`):

```bash
aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:ghr:Application,Values=github-action-runner" \
  --query 'Reservations[*].Instances[*].[InstanceType,Tags[?Key==`ghr:environment`]|[0].Value]' \
  --output text | sort | uniq -c | sort -rn
```

## Migration from Legacy Single-Fleet Layout

If migrating from the previous top-level `../../` module setup (single arm64 fleet only), see CLAUDE.md → "从单 runner（顶层 module）迁移到 multi-runner". Plan for a maintenance window — switching modules destroys and recreates SQS / Lambda / IAM resources, and the webhook URL changes.

## Cost Notes

| Resource | Approx cost |
|----------|-------------|
| EC2 Spot `c8g.2xlarge` | ~$0.11–0.16/hr |
| EC2 Spot `c7a.4xlarge` | ~$0.30–0.40/hr |
| Lambda + SQS + S3 | ~$0.50–1.00/mo |
| NAT Gateway | (already exists, shared with VPC) |

Idle fleet cost is essentially the Lambda + SQS + S3 baseline. Runners only cost money while jobs are running (plus the 15-min idle window after the last job).
