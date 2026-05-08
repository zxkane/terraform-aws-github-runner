# Shared GitHub Actions Runner Deployment — Operations Handbook

This deployment is shared across multiple projects. Jobs route to architecture-specific fleets via GitHub labels (`arm64` / `x64`).

## Deployment Info

- **Deployment dir**: `deployments/shared-runners/`
- **AWS Region**: us-east-1
- **Terraform state**: S3 backend, key = `github-runner/terraform.tfstate`
- **Backend init**: `terraform init -backend-config="bucket=<state-bucket>"` — pass **only** `bucket`, **never** `dynamodb_table` (see "State Locking" below)
- **Terraform module**: `modules/multi-runner` (manages both arm64 and amd64 fleets behind a single GitHub App webhook)

### State Locking

**This deployment uses a pure S3 backend with no DynamoDB locking.** `scripts/01-create-tf-backend.sh` historically declared a lock-table creation step, but the DynamoDB table never actually existed — the state file lives only in S3.

Consequences:
- ✅ Single-operator deployment works fine — only one writer
- ⚠️ Concurrent `terraform apply` from multiple operators or machines has no lock protection and may overwrite state
- ⚠️ `terraform init -backend-config="dynamodb_table=..."` fails with `ResourceNotFoundException` because the table doesn't exist

If concurrency protection is needed later:
- **Preferred**: upgrade to Terraform 1.10+ and switch to S3 native locking (`use_lockfile = true`) — zero extra resources
- **Alternative**: run `01-create-tf-backend.sh` (the DynamoDB creation logic is already there) to create the lock table, then pass `dynamodb_table=...` on init

The deployment / migration scripts (`03-deploy.sh`, `04-migrate-to-multi-runner.sh`) intentionally pass only `bucket` on init. Don't set `TF_STATE_LOCK_TABLE` in `.deploy.env`.

## Fleet Layout

| Fleet | Architecture | Instance types | Max | AMI filter | Purpose |
|-------|--------------|----------------|----:|-----------|---------|
| `linux-arm64` | arm64 | `c8g.2xlarge` (Graviton4) | 10 | `github-runner-ubuntu-noble-arm64-*` | General CI |
| `linux-amd64` | x64 | `c7a.4xlarge` / `c7i.4xlarge` / `m7a.4xlarge` | 5 | `github-runner-ubuntu-noble-amd64-*` | GPU container image builds (no GPU on the runner host itself) |

Shared config across both fleets: persistent runners, 15-min idle timeout, Spot with `price-capacity-optimized` allocation, 60 GB encrypted gp3 root, SSM enabled, no userdata, runner binary pre-installed in the AMI.

## Workflow Configuration

Pick the architecture each job needs and write the matching `runs-on`:

```yaml
# arm64 (general CI)
runs-on: [self-hosted, linux, arm64]

# amd64 (e.g. building GPU container images)
runs-on: [self-hosted, linux, x64]
```

Each fleet has `exactMatch=true` on its label matcher, so a job's labels must match the fleet's labels exactly — jobs cannot leak across architectures.

## Passing Terraform Variables

Variables aren't stored in `tfvars` files; they're passed at runtime. Existing values can be pulled from state:

```bash
# Extract the GitHub App key (for plan/apply)
KEY_B64=$(terraform state pull | python3 -c "
import json,sys
state = json.load(sys.stdin)
for r in state.get('resources', []):
    if r.get('type') == 'aws_ssm_parameter':
        for inst in r.get('instances', []):
            if 'github_app_key_base64' in inst.get('attributes',{}).get('name',''):
                print(inst['attributes']['value'], end='')
")

terraform plan \
  -var="github_app_id=<APP_ID>" \
  -var="github_app_key_base64=$KEY_B64" \
  -var="vpc_id=<VPC_ID>" \
  -var='subnet_ids=["<SUBNET_1>","<SUBNET_2>","<SUBNET_3>"]' \
  -out=tfplan

terraform apply tfplan
```

## Migrating From a Legacy Single-Fleet Deployment

History: this deployment originally used the top-level `../../` module wrapper, which only supported a single arm64 fleet. It was later switched to `modules/multi-runner` to host both arm64 and amd64 fleets.

The module switch forces Terraform to destroy and recreate every resource, because resource paths and naming change shape. Two approaches:

**Option A: destroy + recreate (recommended, low risk)**
- Webhook URL changes (the GitHub App webhook URL is auto-synced by `modules/webhook-github-app`'s local-exec)
- SQS / Lambda / IAM are all recreated with `-linux-arm64` / `-linux-amd64` suffixes
- Run inside a maintenance window
- ~5–10 min of queued jobs while the new stack comes up

**Option B: `terraform state mv` (high risk, not recommended)**
- multi-runner resources live under `module.runners.module.runners["linux-arm64"].*`; legacy ones live under `module.runners.*`
- Even if `state mv` succeeds, the SQS naming change still triggers destroy + create
- Not worth the risk of corrupting state

Option A walkthrough is in `scripts/04-migrate-to-multi-runner.sh`. The script restores the legacy `main.tf` for the destroy phase, switches to the current `main.tf` for apply, and verifies via JWT-signed `GET /app/hook/config` that the GitHub App webhook URL synced correctly.

## Architecture Notes

### How `runners_maximum_count` works

`runners_maximum_count` is enforced in the scale-up Lambda (`lambdas/functions/control-plane/src/scale-runners/scale-up.ts`):
- On every scale-up invocation, the Lambda queries the current EC2 runner count
- New runners created = `Math.min(requested, maximumRunners - currentCount)`
- `scale_up_reserved_concurrent_executions` defaults to 1, so only one Lambda instance executes at a time, avoiding race conditions

### Persistent runner scale-down

- The scale-down Lambda runs every minute
- Runners idle for more than `minimum_running_time_in_minutes` (15 min) are terminated
- During traffic bursts, runners pile up to the cap and only get reclaimed once the burst dies down

### Spot allocation strategy

- Use `price-capacity-optimized` instead of `lowest-price`: AWS-recommended; balances price against interruption rate
- arm64 fleet uses a single instance type (`c8g.2xlarge` — Graviton4 is available in all five us-east-1 AZs)
- amd64 fleet uses a multi-pool list (`c7a.4xlarge` / `c7i.4xlarge` / `m7a.4xlarge`); the allocator picks whichever pool has best capacity at the time of launch
- For higher availability, set `enable_on_demand_failover_for_errors` to fall back to on-demand when spot fails

### Per-project usage tracking

Don't tag the EC2 instances with `Project=...` — a single runner serves jobs from many repos in its lifetime, so instance-level project tags can't accurately attribute usage.

**Use CloudWatch Logs Insights against the webhook Lambda log instead, not CloudWatch Metrics.** The upstream Lambdas don't emit `repository` as a metric dimension (only as EMF metadata, which can't be aggregated in Metrics Explorer). The webhook Lambda does log full repo / job / action / conclusion on every `workflow_job` event, which is enough for usage and cost attribution.

Log group: `/aws/lambda/<prefix>-webhook` (e.g. `gh-runner-webhook`)

Each line includes a nested `github` object with these queryable fields:
- `github.repository` — `owner/repo`
- `github.action` — `queued` / `in_progress` / `completed`
- `github.name` — workflow job name
- `github.conclusion` — `success` / `failure` / `skipped` / `cancelled` (only set when `action = completed`)
- `github.started_at` / `github.completed_at` — ISO timestamps
- `github.workflowJobId` — unique per job; useful for joining queued + completed events

Example: count events by repo and action

```sql
fields @timestamp, github.repository as repo, github.action as action
| filter ispresent(github.repository)
| stats count() as events by repo, action
| sort events desc
```

Example: wall-clock job time per repo, derived from `@timestamp` differences between the queued and completed events for the same `workflowJobId` (Logs Insights can't math on ISO strings directly):

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
        avg(wall_sec) as avg_wall_sec
        by repo
| sort total_wall_sec desc
```

`wall_sec` is GitHub's wall-clock view — it includes runner queue time. For pure compute time, key the same query off `action` events instead.

If you eventually want a true Metrics Explorer dashboard with a `Repository` dimension, you'll need to fork the Lambda code and add a `createSingleMetric('ScaleUp', ..., { Repository: '...' })` call in `scale-up.ts`. That's out of scope for this deployment.

## AMI Build

Two Packer directories, structurally aligned:

- `images/ubuntu-noble-arm64/` — arm64, builder instance `t4g.large`
- `images/ubuntu-noble/` — amd64, builder instance `t3.large`

Each directory has a `shared.pkrvars.hcl` for build-time inputs (force-added past `images/.gitignore` which excludes `*.pkrvars.hcl`; nothing sensitive lives there).

Build script accepts an architecture switch:

```bash
cd deployments/shared-runners
ARCH=arm64 ./scripts/02-build-ami.sh
ARCH=amd64 ./scripts/02-build-ami.sh
```

AMI security/freshness baseline (both architectures must satisfy):
- **IMDSv2-only**: Packer source has `imds_support = "v2.0"` so the resulting AMI registers IMDSv2-only. The Packer builder instance also has `metadata_options { http_tokens = "required" }` because AWS accounts with `httpTokensEnforced` reject any IMDSv1 launch
- **Latest patches**: `apt-get -y upgrade` (with `force-confdef` + `force-confold`) at build time
- **Base AMI**: Canonical `ubuntu-pro-server/images/hvm-ssd-gp3/ubuntu-noble-24.04-{arm64,amd64}-pro-server-*`
- Runner binary pre-installed (`enable_runner_binaries_syncer = false`)
- No userdata at boot (`enable_userdata = false`)

Toolchain shared by both architectures: Node.js 24, Bun, Playwright Chromium, Docker CE, AWS CLI v2, CloudWatch Agent.

## Other Notes

- `runner_run_as = "ubuntu"`: Ubuntu AMIs use the `ubuntu` user, not `ec2-user`
- `delay_webhook_event = 30`: gives an idle runner 30 seconds to pick up a queued job before the scale-up Lambda decides to add capacity
- Runner EC2 tags: `ManagedBy = "github-actions-runner"`, `SharedInfra = "true"` — **no Project tag** (see "Per-project usage tracking" above)
- Clean up `tfplan` after deploys
- `.gitignore` already excludes `CLAUDE.local.md`, `*.local.*`, `tfplan`, `.terraform/`
