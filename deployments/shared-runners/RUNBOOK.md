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

## Step 3: Build Custom AMIs

Build both architectures (or just one, as needed):

```bash
cd deployments/shared-runners
ARCH=arm64 ./scripts/02-build-ami.sh
ARCH=amd64 ./scripts/02-build-ami.sh
```

Each AMI includes: Node.js 24, Bun, Playwright Chromium, Docker CE, AWS CLI v2, GitHub Actions runner. IMDSv2 is enforced; the latest apt patches are applied at build time.

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

## Step 6: Update CI Workflows

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
| AMI | `github-runner-ubuntu-noble-arm64-*` | `github-runner-ubuntu-noble-amd64-*` |
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
