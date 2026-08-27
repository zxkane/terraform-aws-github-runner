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
| `linux-arm64` | arm64 | `c8g.2xlarge` (Graviton4) | 10 | `github-runner-ubuntu-resolute-arm64-*` | General CI |
| `linux-amd64` | x64 | `c7a.4xlarge` / `c7i.4xlarge` / `m7a.4xlarge` | 5 | `github-runner-ubuntu-resolute-amd64-*` | GPU container image builds (no GPU on the runner host itself) |

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

## Changes to `feat/multi-runners` go through a pull request

**Direct pushes to `feat/multi-runners` get almost no CI.** Every quality gate
this fork inherits from upstream fires on `pull_request`, and the few that also
fire on `push` are pinned to `main`:

| Workflow | `push` trigger | `pull_request` trigger |
|---|---|---|
| `terraform.yml` (fmt, validate, tflint) | `main` only | yes, paths `**/*.tf`, `**/*.hcl` |
| `lambda.yml` (build, lint, test) | none | yes, paths `lambdas/**` |
| `ami-release-checks.yml` | none | yes, paths `deployments/shared-runners/**`, `images/**`, `lambdas/**`, … |
| `zizmor.yml`, `packer-build.yml` | `main` only | yes |
| `codeql.yml` | `main`, `develop`, `v1` | yes |
| `ovs.yml` (OSV scanner), `semantic-check.yml` | none | yes, unfiltered |
| `update-docs.yml` | any branch | n/a |

`feat/multi-runners` is this fork's **default** branch but is not named `main`,
so a direct push triggers only CodeQL and the docs regeneration. Everything
else — Terraform validation, the Lambda test suite, the AMI release checks — is
skipped silently.

A ruleset (`feat/multi-runners requires a pull request`, repo ruleset id in the
GitHub UI) enforces this. Notes on how it is configured and why:

- **Rule: `pull_request`, 0 required approvals.** A single operator cannot
  approve their own PR, so requiring an approval would deadlock every change.
- **Bypass: repository admin, always.** This keeps break-glass pushes possible
  and, more importantly, keeps the force-push that an upstream rebase needs
  working. The ruleset is a speed bump, not a wall — the process is the control.
- **No `non_fast_forward` rule** on purpose, for that same rebase force-push.
- **No required status checks** on purpose. Most workflows are path-filtered, so
  marking them required would block a docs-only PR forever on a check that never
  runs. Read the checks on the PR instead; only `ovs.yml` and
  `semantic-check.yml` run unconditionally.
- **The docs bot has no bypass and cannot be given one.** `update-docs.yml`'s
  `Generate TF docs (forks)` step pushes straight to the branch with
  `GITHUB_TOKEN`, and GitHub rejects an `Integration` bypass actor on a
  user-owned repository. This is fine in the normal flow: the bot regenerates
  docs on the *feature* branch (unprotected), so by merge time there is no diff
  left and its post-merge run pushes nothing. If docs drift does survive a
  merge, the `Update docs` run fails loudly with a rejected push — harmless, but
  fix the docs on a follow-up PR rather than pushing directly.

Rebasing onto a new upstream release still force-pushes `feat/multi-runners`
directly; that is expected and the admin bypass covers it.

## Webhook 网关授权

The webhook route (`POST /webhook` on the HTTP API) carries a Lambda authorizer
so the route is not left with `AuthorizationType=NONE`. **It always allows.**

**A Lambda authorizer cannot verify the GitHub HMAC.** No API Gateway authorizer
payload format carries the request body — neither `1.0` nor `2.0`, for REST or
HTTP APIs — and GitHub computes the signature over that body. Signature
verification therefore lives, and must stay, in the webhook lambda:
`verifySignature()` in `lambdas/functions/webhook/src/webhook/index.ts`, which
rejects an invalid signature with a 401. **Do not remove that check on the
assumption the gateway performs it.** Anyone who wants a real cryptographic gate
at the edge has to put a high-entropy token in the webhook URL itself (GitHub
allows no custom headers) and validate it in the authorizer.

Pieces:
- `lambdas/functions/webhook/src/lambda.ts` → `githubWebhookAuthorizer`, and
  `src/authorizer/` for the origin-signal extraction. It returns
  `{ isAuthorized: true }` unconditionally, calls no AWS API, reads no
  parameter, and swallows its own logging errors, so it has no failure mode. It
  logs the signals it can see (signature header shape, event type, hook
  installation target, user agent, source IP) purely for observability.
- `deployments/shared-runners/webhook-authorizer.tf` → the lambda (same
  `webhook.zip` artifact, different handler export), its log group, a
  logs-only IAM role, the `aws_apigatewayv2_authorizer`, and the attachment.
- `deployments/shared-runners/scripts/webhook-authorizer.sh` →
  `attach` / `verify` / `detach`, with `webhook-authorizer.test.sh` alongside.

Two configuration details that are load-bearing:
- **`identity_sources = []`.** With an identity source configured, API Gateway
  answers 401 *without invoking the lambda* whenever that header is absent. An
  empty list keeps every request on the lambda, which always allows.
- **`authorizer_result_ttl_in_seconds = 0`.** Caching needs an identity source
  to key on, so it stays off.

### Why attachment happens outside Terraform

`modules/webhook/main.tf` deliberately sets
`ignore_changes = [authorizer_id, authorization_type, authorization_scopes]` on
the route (upstream PR #4000, "Enable authorizer assignment to webhook"). The
reason is a dependency cycle: the authorizer needs the API id, which the module
creates, while the route needs the authorizer id. Upstream left external
assignment as the escape hatch, and this deployment uses it — a `terraform_data`
resource calls `webhook-authorizer.sh attach`, which is `apigatewayv2
update-route`. That keeps `modules/` free of fork-local changes, so rebasing onto
upstream stays trivial.

Consequences to know:
- `update-route` is an **in-place** update. The route is never recreated, so no
  404 window opens and no `workflow_job.queued` event is lost. (GitHub does not
  redeliver, so a lost queued event leaves a job hanging with no runner.)
- The attach step verifies itself: it re-reads the route, then POSTs an unsigned
  request to the live endpoint. A `403` means API Gateway is denying, so the
  script restores `AuthorizationType=NONE` and fails the apply.
- The attachment is not visible in `terraform plan`. If someone detaches the
  authorizer by hand, the next apply re-attaches it; until then the route falls
  back to its pre-change behaviour, which is availability-safe.

Verification, rollback and the Logs Insights query are in
`deployments/shared-runners/RUNBOOK.md` "Step 5a".

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

Two Packer directories, structurally aligned (Ubuntu 26.04 LTS "Resolute Raccoon"):

- `images/ubuntu-resolute-arm64/` — arm64, builder instance `t4g.large`
- `images/ubuntu-resolute/` — amd64, builder instance `t3.large`

Each directory has a `shared.pkrvars.hcl` for build-time inputs (force-added past `images/.gitignore` which excludes `*.pkrvars.hcl`; nothing sensitive lives there).

Build script accepts an architecture switch:

```bash
cd deployments/shared-runners
ARCH=arm64 ./scripts/02-build-ami.sh
ARCH=amd64 ./scripts/02-build-ami.sh
```

This script is break-glass/manual and does not create a managed release.
Normal builds are dispatched by `.github/workflows/ami-release.yml`: every
Monday at `02:37 UTC`, or manually for `all`, `amd64`, or `arm64`. Each
architecture uses a private Session Manager builder and validates the final
AMI on a separate SSM-managed On-Demand instance.

AMI security/freshness baseline (both architectures must satisfy):
- **IMDSv2-only**: Packer source has `imds_support = "v2.0"` so the resulting AMI registers IMDSv2-only. The Packer builder instance also has `metadata_options { http_tokens = "required" }` because AWS accounts with `httpTokensEnforced` reject any IMDSv1 launch
- **Latest patches**: `apt-get -y upgrade` (with `force-confdef` + `force-confold`) at build time
- **Base AMI**: Canonical `ubuntu-pro-server/images/hvm-ssd-gp3/ubuntu-resolute-26.04-{arm64,amd64}-pro-server-*`
- **Empty apt index**: the build ends with `apt-get clean && rm -rf /var/lib/apt/lists/*` so the AMI never ships a stale package index. The index frozen at bake time ages with the image and points at package versions Ubuntu's archive rotates out each point-release; a consumer that runs `apt-get install <pkg>.deb` without a preceding `apt-get update` would otherwise 404 on a rotated dependency. Clearing the lists forces the runner's first apt op to fetch a fresh index. (Consumers should still `apt-get update` before installing.)
- **cloud-init degraded tolerance**: the first provisioner runs `cloud-init status --wait || [ $? -eq 2 ]` — exit 2 means cloud-init finished in a degraded (recoverable) state, common on a fresh 26.04 first boot; only exit 1 (crash) fails the build.
- Runner binary pre-installed (`enable_runner_binaries_syncer = false`)
- No userdata at boot (`enable_userdata = false`)

Toolchain shared by both architectures: Node.js 24, Bun, Playwright Chromium, Docker CE, AWS CLI v2, GitHub CLI (`gh`), CloudWatch Agent. The amd64 AMI also includes the latest Google Chrome Stable release available when the image is built.

### Rolling out a new AMI

Terraform owns the six active/previous/recovery parameter resources and ignores
their values. Recovery is an internal durable compensation-protection channel,
not an operator-selectable release. The release workflows own value changes:

- `ami-promote.yml` validates an exact passed build attempt, writes
  `(active, previous, recovery) = (candidate, old-active, old-previous)`, and
  verifies the resolved Launch Template.
- `ami-rollback.yml` stores old active in recovery, then restores
  `active = previous` for one architecture.
- Both use per-architecture non-cancelling concurrency and compensate failed
  writes through read-back.
- Auto-promotion defaults off independently for amd64 and arm64.

The housekeeper deletes unreferenced managed AMIs strictly older than seven days
every Monday at `08:37 UTC`. Active, previous, recovery and resolved Launch
Template images stay protected. The dry-run gate was reviewed and cleared on
2026-08-27, and `ami_housekeeper_dry_run` now **defaults to `false`** in
`deployments/shared-runners/variables.tf`.

**The default has to carry that decision, not a `-var` on the command line.**
`scripts/03-deploy.sh` does not pass `ami_housekeeper_dry_run`, so a `true`
default would silently return the housekeeper to dry-run on the next routine
deploy. To pause cleanup, edit the default.

**Break-glass AMIs are outside the housekeeper's reach.** It filters on
`tag:ghr:managed = runner-ami-release`, and its IAM policy conditions
`ec2:DeregisterImage` / `ec2:DeleteSnapshot` on that same tag. Images built by
`scripts/02-build-ami.sh` (name form `…-YYYYMMDDHHMM` instead of
`…-<run-id>.<attempt>`) carry no such tag, so they accumulate until an operator
removes them by hand. Five of them were purged on 2026-08-27. If you use the
break-glass path, clean up after it.

`ec2:DeregisterImage` is eventually consistent: `describe-images` can still
resolve a just-deregistered AMI. Poll until it stops resolving before deleting
its snapshot, otherwise a registered AMI can end up with no backing snapshot.

See `deployments/shared-runners/RUNBOOK.md` for GitHub variable setup,
promotion, rollback, monitoring and cleanup gates.

After apply, **already-running spot instances keep the old AMI** (root volume was baked at launch). They get replaced when scale-down recycles them after `minimum_running_time_in_minutes` (15 min) of idle. To roll faster, terminate idle ones manually — but **don't terminate `busy=true` runners** unless you mean to kill the in-flight job. Use the GitHub App JWT to check `busy` per runner before terminating; the dispatcher pattern is in this file's history (search for `app/installations` + `actions/runners`).

GitHub keeps an entry per runner indefinitely after the EC2 instance dies; you'll see `status=offline` ghosts in the runners list. SSM housekeeper Lambda or a periodic GitHub-side cleanup is needed to prune them — out of scope here.

### Workspace hygiene hook

Both AMIs ship a job-started hook at `/opt/actions-runner/hooks/job-started.sh` (source: `images/hooks/job-started.sh`). It's wired in via `ACTIONS_RUNNER_HOOK_JOB_STARTED` in `/opt/actions-runner/.env`, so the runner agent runs it before every job.

What it does: wipes the contents of per-repo workdirs under `/opt/actions-runner/_work` (skips **every `_`-prefixed entry** — `_actions`, `_temp`, `_tool`, `_PipelineMapping`, `_update`, `_diag`, …; those are all runner-internal and never a repo workdir). This forces `actions/checkout@v4` to take its full-clone path on every job.

Why: when a workflow with `concurrency.cancel-in-progress: true` SIGTERMs an in-flight `actions/checkout` step, the leftover `_work/<repo>/<repo>/` can be in a state where `.git/index` is "consistent" with an empty working tree. The next job on the same persistent runner sees a workdir that `git clean -ffdx && git reset --hard HEAD && git checkout --force -B <branch>` all treat as already-clean — checkout returns success but the workdir stays empty. The first step that actually reads files (typically `npm ci`) fails with `ENOENT`. Short jobs that don't read the workdir succeed silently against an empty checkout, which is more dangerous than the loud failure.

**Two footguns the hook is hardened against** (both bit downstream on 2026-06-15 — see the spec):
1. **`_update` is runner-internal.** The runner self-update stages a new release (including `externals/node20/…`) under `_work/_update/`. The original fixed skip-list missed it, so the hook ran `find -delete` over residue the `ubuntu` user can't always unlink → `find` errored → under `set -e` the hook aborted → the runner **failed healthy jobs before any step ran**. The skip-list now matches `_*`, so the hook never touches it.
2. **Cleanup is best-effort, never fatal.** The per-workdir `find -delete` is wrapped so a delete failure (e.g. a root-owned file left by a Docker step) logs a warning to stderr and continues instead of failing the job. `find` still strips the corrupted `.git/index`, so checkout re-clones. Housekeeping must never fail a customer job.

There's a self-contained test for both at `images/hooks/job-started.test.sh` — run `bash images/hooks/job-started.test.sh` after any change to the hook.

**No opt-out by design.** A future operator who finds the hook "slowing things down" because every job re-clones should not strip it without re-reading `docs/superpowers/specs/2026-05-25-job-started-hook-design.md`. The most likely "I want to opt out for caching" case is exactly the case where the bug bites (long-lived persistent runner serving multiple jobs).

## Other Notes

- `runner_run_as = "ubuntu"`: Ubuntu AMIs use the `ubuntu` user, not `ec2-user`
- `delay_webhook_event = 30`: gives an idle runner 30 seconds to pick up a queued job before the scale-up Lambda decides to add capacity
- Runner EC2 tags: `ManagedBy = "github-actions-runner"`, `SharedInfra = "true"` — **no Project tag** (see "Per-project usage tracking" above)
- Clean up `tfplan` after deploys
- `.gitignore` already excludes `CLAUDE.local.md`, `*.local.*`, `tfplan`, `.terraform/`
