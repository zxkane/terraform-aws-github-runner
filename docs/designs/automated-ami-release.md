# Design Canvas - Automated Runner AMI Release

Feature: Periodic dual-architecture runner AMI release
Date: 2026-07-30
Status: Closed

## Scope

Build and validate fresh Ubuntu 26.04 runner AMIs for amd64 and arm64 every
week. Promote or roll back each architecture independently through existing
SSM Parameter Store channels, and delete unreferenced release AMIs after seven
days.

Each architecture automatically promotes after its build and final-AMI
validator succeed. No human deployment review is part of the release gate.
An architecture-specific repository variable can pause automatic promotion,
and the one-level rollback workflow remains available for recovery.

## Components

```text
GitHub-hosted Actions (ubuntu-24.04)
  |
  +-- ami-release.yml
  |     +-- schedule: 37 2 * * 1
  |     +-- manual: all | amd64 | arm64
  |     +-- explicit amd64 and arm64 calls to ami-build.yml
  |
  +-- ami-build.yml (reusable, one architecture)
  |     +-- Packer build over Session Manager
  |     +-- final-AMI validator over SSM Run Command
  |     +-- architecture-scoped auto-promotion
  |
  +-- ami-promote.yml (manual release_id promotion)
  +-- ami-rollback.yml (manual previous-channel rollback)
        |
        v
AWS OIDC roles
  +-- build role: image build, validation and candidate tags
  +-- amd64 promotion role: candidate read, amd64 channel write and LT read
  +-- arm64 promotion role: candidate read, arm64 channel write and LT read
        |
        v
Packer -> candidate AMI -> final-AMI validator -> active/previous/recovery channels
        |
        v
Launch Template ImageId = resolve:ssm:<active-parameter-arn>
```

GitHub scheduled workflows run from the default branch and are best-effort;
`02:37 UTC` is the requested start time, not an execution-time SLA.

## Architecture Contract

| Architecture | Packer directory | EC2 architecture | Builder | Validator | Browser contract |
|---|---|---|---|---|---|
| amd64 | `images/ubuntu-resolute` | `x86_64` | `t3.large` | `t3.large` | Playwright Chromium and Google Chrome Stable |
| arm64 | `images/ubuntu-resolute-arm64` | `arm64` | `t4g.large` | `t4g.large` | Playwright Chromium; Google Chrome absent |

Both templates use Packer's `most_recent=true` over one exact Canonical owner
supplied through the validated `AMI_SOURCE_OWNER_ID` repository secret,
architecture-specific Ubuntu 26.04 Pro Server gp3 name filter,
`root-device-type=ebs` and `virtualization-type=hvm`. API response order is not
used. The resulting AMI records Packer's resolved source name in the
`Base_AMI_Name` tag.

For packages, "current at build time" means the version selected by the
configured package repository or upstream release API after its metadata is
refreshed in that build. It does not promise the same version across runs.
Both templates install the selected Node.js 24 release, Bun, Playwright
Chromium, Docker CE, AWS CLI v2, GitHub CLI and GitHub Actions runner. amd64
also installs the selected Google Chrome Stable package. Validation records
installed version output and enforces the stated major/channel and browser
startup contract; it does not compare against a repository that may change
after the build.

## Release Identity And State

`release_id` is public and deterministic:

```text
<github_run_id>.<github_run_attempt>
```

Every release AMI has exactly these workflow-owned tags:

| Tag | Allowed value |
|---|---|
| `ghr:managed` | `runner-ami-release` |
| `ghr:release_id` | the exact release ID |
| `ghr:architecture` | `amd64` or `arm64` |
| `ghr:ami_role` | `builder` |
| `ghr:source_revision` | the 40-character Git commit SHA |
| `ghr:validation_status` | `candidate`, `passed` or `failed` |

Every EBS snapshot created for a release AMI receives the same six tags at
creation; its `ghr:validation_status` remains `candidate` because validation
updates the AMI only. The housekeeper's snapshot-delete IAM condition depends
on `ghr:managed=runner-ami-release`; it MUST NOT have an unconditional
`DeleteSnapshot` allow.

Packer creates `candidate`. The validation workflow replaces it with `passed`
only after every final-image assertion succeeds and bounded read-back observes
`passed`. A failing assertion, registration deadline or validation deadline
causes one best-effort `failed` write. A cancelled workflow or an unavailable
tag API can leave `candidate`; such an image is not promotable and is cleaned
by the same retention rule as `failed`.

If validation succeeds but the single `passed` mutation has an unknown result
or its read-back does not converge, the workflow fails and MUST NOT issue a
conflicting `failed` write. The final tag may be `candidate` or `passed`.
Automatic promotion is not invoked from a failed build job, and all later
promotion still requires an exact readable `passed` tag.

Candidate discovery uses EC2 `DescribeImages` with owner `self`, state
`available`, and exact filters for `ghr:managed`, `ghr:release_id`,
`ghr:architecture` and `ghr:validation_status=passed`. Promotion accepts
`build_run_id`, `build_run_attempt` and `architecture`, never an AMI ID. The
query has a fresh 120-second phase and MUST fully paginate before evaluating
the result count. A page error, deadline, zero results or more than one result
fails before any channel read or write. No implementation may select the first,
newest or other arbitrary match. After selection, the workflow reads the exact
GitHub Actions run attempt and requires `ghr:source_revision` to equal its
40-character `head_sha`.

AMI IDs and AWS account identifiers are internal workflow values. Every
`configure-aws-credentials` invocation enables `mask-aws-account-id`, which
registers the assumed account ID and authenticated ARN as GitHub workflow
masks. Static role, instance-profile, network and source-owner identifiers are
GitHub Actions secrets, so the runner masks them before any step preamble is
logged; reusable workflow callers explicitly pass only the secrets declared by
the called workflow. Commands that can emit dynamic account or resource
identifiers write to a private temporary file with shell tracing disabled.
Scripts register known AMI and instance IDs as masks and sanitize captured
account/AMI/infrastructure identifiers before replaying output. Raw Packer
manifests and AWS responses are never uploaded as artifacts.

## Channel Contract

Terraform owns each parameter's resource, name, type, data type, tags and IAM
policy. Release workflows exclusively own its value.

| Architecture | Channel | Exact parameter name |
|---|---|---|
| amd64 | active | `/github-action-runners/gh-runner/linux-amd64/runners/config/ami_id` |
| amd64 | previous | `/github-action-runners/gh-runner/linux-amd64/runners/config/ami_previous_id` |
| amd64 | recovery | `/github-action-runners/gh-runner/linux-amd64/runners/config/ami_recovery_id` |
| arm64 | active | `/github-action-runners/gh-runner/linux-arm64/runners/config/ami_id` |
| arm64 | previous | `/github-action-runners/gh-runner/linux-arm64/runners/config/ami_previous_id` |
| arm64 | recovery | `/github-action-runners/gh-runner/linux-arm64/runners/config/ami_recovery_id` |

All six are `String` parameters with data type `aws:ec2:image` and:

```hcl
lifecycle {
  prevent_destroy = true
  ignore_changes  = [value]
}
```

The migration preserves the two active parameters with these exact moves:

```hcl
moved {
  from = module.runners.module.runners["linux-amd64"].aws_ssm_parameter.runner_ami_id[0]
  to   = aws_ssm_parameter.runner_ami_active["amd64"]
}

moved {
  from = module.runners.module.runners["linux-arm64"].aws_ssm_parameter.runner_ami_id[0]
  to   = aws_ssm_parameter.runner_ami_active["arm64"]
}
```

Each previous and recovery parameter is initialized from the corresponding
pre-migration active value. Release writers and live cleanup remain disabled
during the migration plan and apply. The runner modules receive the root active
parameter ARN through `ami.id_ssm_parameter_arn`; Launch Template contents
remain `resolve:ssm:<active-parameter-arn>`.

Recovery is a durable protection channel, not a user-selectable release
channel. Before an invocation overwrites active or previous, it writes and
reads back the AMI that its compensation path may need after that overwrite.
Promotion stores its captured previous value; rollback stores its captured
active value. A successful invocation leaves recovery unchanged. The next
invocation may overwrite it only while the new compensation source is still
referenced by active or previous. A stale recovery value is therefore expected
and pins at most one additional generation until the next channel mutation.

## Build And Validation Protocol

1. The architecture job assumes the build role using GitHub OIDC.
2. Packer launches a private builder with no public IP and no ingress. It uses
   `communicator = "ssh"` with `ssh_interface = "session_manager"`.
3. `launch_block_device_mappings.encrypted=true` encrypts builder root storage,
   so the resulting AMI snapshot is already encrypted. `encrypt_boot` remains
   unset to avoid Packer's redundant `CopyImage` and temporary-image cleanup
   path. Builder metadata requires IMDSv2 and the AMI registers
   `ImdsSupport=v2.0`.
4. Packer applies current OS updates and installs the architecture contract.
5. The workflow masks the candidate AMI ID, confirms provenance tags and state,
   then launches an On-Demand validator from that final AMI. `RunInstances`
   uses the deterministic client token
   `ghr-validator-<release_id>-<architecture>` and is never blindly retried.
6. The validator has no public IP, no ingress and IMDSv2-only metadata with
   instance metadata tags enabled. Its instance and volume carry exact
   `ghr:managed`, `ghr:ami_role=validator`, `ghr:release_id` and
   `ghr:architecture` tags; the instance also receives
   `ghr:ami_validation=true`.
7. The baked `images/start-runner.sh` reads that tag before invoking the normal
   runner startup template. A `true` value exits successfully before any
   production Parameter Store or GitHub token read. The validator role has no
   `ssm:GetParameter*` or `kms:Decrypt` permission as a second boundary.
8. Before `RunInstances`, the workflow persists a launch-attempt marker. After
   a valid response, it persists the instance ID. Validator user data schedules
   shutdown within two hours and sets instance shutdown behavior to terminate.
   This is a fallback only if user data executes; it does not turn an
   unconfirmed workflow cleanup into success.
9. A 120-second `always()` cleanup classifies launch state as `PRELAUNCH` when
   no marker exists, `KNOWN` when a valid local instance ID exists, or
   `LAUNCH_UNKNOWN` when the marker exists without an ID. Every lookup fully
   paginates `DescribeInstances` with exact managed, validator-role, release,
   architecture and `pending|running|stopping|stopped` filters. IDs are
   validated, masked and deduplicated by `InstanceId`.
10. `KNOWN` cleanup seeds the termination set with the local ID, performs
    exactly one complete fallback lookup and attempts `TerminateInstances` at
    most once per unique ID. It succeeds only if the lookup completes within
    the phase and every termination request returns success; it does not poll
    for terminal instance state. A lookup or termination failure fails cleanup.
11. `LAUNCH_UNKNOWN` MUST NOT retry `RunInstances` and MUST repeat complete
    paginated lookups for the entire cleanup deadline because an initial zero
    result is provisional under EC2 eventual consistency. It attempts
    `TerminateInstances` at most once per discovered ID. At the deadline it
    succeeds only if at least one ID was observed and every termination request
    returned success. If no ID is ever observed, cleanup and the job end
    `UNCONFIRMED_LAUNCH`; a lookup that cannot complete within the phase or any
    termination failure also fails cleanup. `PRELAUNCH` with zero matches is
    success.
12. The workflow waits at most 10 minutes for the validator to register as an
   online Systems Manager managed node. A registration timeout fails
   validation and enters the same instance-termination cleanup path. After
   registration, Run Command checks cloud-init, architecture, IMDSv2,
   image-level IMDS support, tool versions, Docker, browser startup, runner
   files and an empty `/var/lib/apt/lists`.
13. The workflow tags the AMI `passed` only after the command succeeds and a
    bounded read-back observes `passed`. The failure-tag and passed-tag unknown
    result rules above apply. Channel values are not read or written by the
    build job. Cleanup failure is logged separately but cannot turn a failed
    validation into success.

All release workflow and housekeeper elapsed-time deadlines use a monotonic
clock. A phase starts immediately before its first AWS request. Each direct AWS
request has a hard timeout of at most 30 seconds and, when enclosed by a phase,
no longer than that phase's remaining time. At `now >= deadline`, no request or
sleep may start, and an observation completing at or after the boundary does
not satisfy the phase. Polling sleeps are truncated to the remaining time.
Read-only calls may use bounded retries within their phase. A timed-out or
transport-ambiguous mutation, including `RunInstances`, `CreateTags`, `PutParameter`,
`TerminateInstances`, `DeregisterImage` or `DeleteSnapshot`, MUST NOT be
retried; only its specified read-back reconciliation may follow.

Promotion and rollback job timeouts MUST exceed the sum of configured maximum
sequential phase deadlines on their longest compensation path, plus at least
60 seconds for workflow overhead. A job-timeout kill is treated as a
force-cancellation, but the normal configuration MUST leave enough time for
one invocation to finish compensation without relying on a rerun.

Systems Manager registration has its own 10-minute phase, Run Command polling
has its own 20-minute phase, passed-tag convergence has its own 120-second phase
and cleanup has its own 120-second phase.

| Status/result | Action |
|---|---|
| `InvocationDoesNotExist`, `Pending`, `InProgress`, `Delayed` | Retry with bounded backoff before the deadline |
| `Success` | Parse and accept only a zero-exit validation result |
| `Cancelled`, `Cancelling`, `Failed`, `TimedOut`, `Delivery Timed Out`, `Execution Timed Out` | Mark validation failed |
| Deadline exceeded or unknown status | Mark validation failed |

## Promotion Protocol

Promotion and rollback for one architecture share:

```yaml
concurrency:
  group: runner-ami-channel-<architecture>
  cancel-in-progress: false
```

The lock covers candidate validation, all reads, all writes and post-write
verification. Manual force-cancellation remains possible, so every invocation
reconciles observed state before writing.

For candidate `C`, each promotion invocation freezes UTC evaluation time `T`
before candidate lookup, then captures its own `A = active`, `P = previous` and
`R = recovery`:

1. Validate `A`, `P` and `C` are available, account-owned images of the target
   architecture and validate the exact release identity for `C`.
2. If `C == A`, perform no writes, leave `P` unchanged, verify within 15
   minutes that the Launch
   Template resolves to `C`, and succeed.
3. For `C != A`, require `CreationDate > T - 168 hours`. Equality is too old.
   The gate uses the frozen `T`, not `release_id` or a later wall-clock read.
4. Establish recovery. If `R == P`, skip the redundant mutation. Otherwise
   issue exactly one `recovery=P` write and read it back within 120 seconds.
   Then read all three channels and require `(A,P,P)`. An unchanged or unknown
   recovery result is `RECOVERY_NOT_CONFIRMED`; an unexpected readable value or
   readable active/previous drift is `EXTERNAL_DRIFT`; an unreadable channel is
   `PRECONDITION_UNREADABLE`. All three stop before a destructive write, are not
   `COMPENSATION_FAILED`, and issue no compensation write. The same full-tuple
   read and classification apply when the recovery mutation was skipped because
   `R==P`.
5. If `P != A`, issue exactly one `previous=A` write; otherwise skip the
   redundant mutation. Read all three channels within 120 seconds.
6. `(A,A,P)` continues to the active write. `(C,A,P)` is already the desired
   state, so skip the active write. Any other readable tuple or unreadable
   channel ends `COMPENSATION_FAILED` without another write if `previous=A`
   was issued; if it was skipped because `P==A`, the pre-destructive
   `EXTERNAL_DRIFT` or `PRECONDITION_UNREADABLE` classification applies.
7. From `(A,A,P)`, issue exactly one `active=C` write.
8. Read all three parameters for at most 120 seconds until they equal
   `(C,A,P)`. Any different readable tuple, including `(C,A,X)`, or an
   unreadable channel after the active mutation ends `COMPENSATION_FAILED`
   without another write.
9. Run `DescribeLaunchTemplateVersions` for `$Default` with
   `ResolveAlias=true` for at most 15 minutes until the resolved ImageId equals
   `C`, then re-read and require the complete tuple `(C,A,P)` before success.
   A readable tuple mismatch or unreadable channel at that point fails
   immediately; it is not retried as alias propagation.

Each write read-back and final channel convergence phase owns a fresh
120-second deadline. Launch Template alias convergence has a separate
15-minute deadline because EC2's resolved view can lag behind successful
Parameter Store read-back. Because `aws:ec2:image` validation is asynchronous,
an HTTP success from `PutParameter` is never sufficient. The workflow polls
with bounded backoff: observing the target classifies the write as applied;
observing only the captured source value through the deadline classifies it as
unchanged; an unexpected readable value is external drift; and a deadline with
no readable value is unknown. It never repeats a write whose result is
uncertain. After recovery is confirmed, every reconciliation, write read-back,
final convergence check and compensation read evaluates the full
`(active,previous,recovery)` tuple. A two-channel projection MUST NOT authorize
a write or success.

After recovery is confirmed, the only workflow-owned tuples for that invocation
are:

| `(active, previous, recovery)` | Meaning | Allowed action |
|---|---|---|
| `(A,P,P)` | Recovery established; no destructive write applied | If `P != A`, write `previous=A`; otherwise treat the identical `(A,A,P)` state as ready for active |
| `(A,A,P)` | Previous applied; active not applied | Write `active=C`, or compensate by restoring `previous=P` |
| `(C,A,P)` | Desired promotion state or active applied | Verify success, or compensate active then previous |

Compensation starts by reading all three channels. It writes only from one of
the tuples above: restore `active=A` from `(C,A,P)`, verify `(A,A,P)`, then
restore `previous=P`; skip the active write from `(A,A,P)` and restore
`previous=P`; or accept `(A,P,P)` as already restored. Before each compensation
write it re-reads and verifies the expected tuple. Any unreadable channel or
other tuple is external drift: issue no further `PutParameter`, end
`COMPENSATION_FAILED`, and require operator reconciliation.

A force-cancelled invocation has no durable transaction identity. A rerun is a
new invocation that captures the channels as they exist then and may overwrite
old recovery only after confirming its new compensation source is still in
active or previous. It promises to compensate only to its own captured
`(A,P)`, not to an earlier invocation's state.

## Rollback Protocol

Rollback accepts only `architecture` and captures
`A = active`, `P = previous`, `R = recovery`:

1. Validate both images are available, account-owned and match the architecture.
2. If `A == P`, perform no write, verify the Launch Template and succeed.
3. Establish recovery. If `R == A`, skip the redundant mutation. Otherwise
   issue exactly one `recovery=A` write and read it back within 120 seconds.
   Read all three channels and require `(A,P,A)`. Failure or drift before the
   active write follows the same pre-destructive classification as promotion
   and issues no compensation write, including when the recovery mutation was
   skipped because `R==A`.
4. From `(A,P,A)`, issue exactly one `active=P` write; previous and recovery
   remain unchanged.
5. With an independent 120-second channel deadline and 15-minute Launch
   Template alias deadline, verify the complete tuple equals `(P,P,A)` and the
   `$Default` Launch Template with `ResolveAlias=true` resolves to `P`. Re-read
   and require `(P,P,A)` when the alias matches before reporting success. A
   readable tuple mismatch or unreadable channel fails immediately.
6. If write read-back or verification fails, read all three channels again.
   `(A,P,A)` means the write did not apply or was already restored: perform no
   write and fail normally. `(P,P,A)` allows one compensation write restoring
   and verifying `active=A`. Any unreadable channel or other tuple is external
   drift and ends `COMPENSATION_FAILED` without overwriting it. Previous and
   recovery remain unchanged.

Rollback is intentionally one level. It is not an active/previous swap.

## IAM And Network Boundaries

- Every job that allocates a runner uses GitHub-hosted `ubuntu-24.04`;
  reusable-workflow caller jobs allocate no runner themselves.
- Every third-party action is pinned to a full commit SHA.
- OIDC trust always requires
  `token.actions.githubusercontent.com:aud = sts.amazonaws.com`.
- The build role trusts only
  `repo:<owner>/<repo>:ref:refs/heads/<default-branch>`.
- The amd64 promotion role trusts only
  `repo:<owner>/<repo>:environment:runner-ami-production-amd64`.
- The arm64 promotion role trusts only
  `repo:<owner>/<repo>:environment:runner-ami-production-arm64`.
- Both environments restrict deployments to the default branch and have no
  required reviewers or wait timer. The environment binding supplies the
  architecture-specific OIDC subject, not a human approval gate.
- The build role cannot write channel parameters.
- The build role launches only tagged `t3.large`/`t4g.large` instances in the
  configured subnet with the builder or validator profile. Create/tag/image and
  lifecycle permissions are split by resource type and require
  `ghr:managed=runner-ami-release`.
- Packer can start only `AWS-StartPortForwardingSession` sessions on tagged
  builder instances and can resume/terminate only sessions owned by the current
  role session.
- A promotion role cannot build, register, deregister or copy images. Its
  SSM parameter read and write permissions cover only the active, previous and
  recovery parameters for its architecture.
- Builder and validator instance profiles contain only managed-node messaging
  permissions. The validator profile cannot read Parameter Store or decrypt
  KMS data.
- Builder and validator security groups contain no ingress. Their private
  subnets use the deployment's existing NAT path for package downloads and AWS
  service access.
- The housekeeper uses a dedicated Lambda execution role. It can read exactly
  the six channel parameters, describe images and Launch Template versions,
  and deregister/delete only release-managed AMIs and snapshots admitted by
  its policy conditions. It cannot write SSM parameters, create/copy/register
  images, manage instances or perform IAM mutations. Logging and optional VPC
  execution permissions remain separate from the cleanup policy.

## Housekeeper Protocol

The deployment creates one AMI housekeeper configured from the same Terraform
channel-name locals with the six exact channel names and the two exact runner
Launch Template names. At invocation start it freezes one injectable UTC
evaluation time `T`, logs it, resolves the complete protection set exactly
once, then enumerates every page of deletion candidates. Every image in that
invocation uses the same `T` and protection set; candidate pagination never
refreshes protection sources.

For each architecture the housekeeper MUST resolve all three explicit
parameters sequentially in `active`, `previous`, `recovery` order and add every
well-formed value it observes to the frozen protection set. It MUST NOT skip
recovery based on active/previous equality. The serialized channel writer
confirms recovery before overwriting either source, so an ordered reader
observes a compensation source in an earlier active/previous read or in its
later recovery read without assuming a multi-key atomic snapshot. Wildcards
are not used for these six names.

For each exact Launch Template name, the housekeeper reads only `$Default` with
`ResolveAlias=true` and protects the final AMI ID returned in `ImageId`. A
missing template/version, unresolved SSM alias, non-AMI result or multiple
unexpected versions is a fail-closed protection error.

Protection resolution is fail-closed. A missing parameter, missing requested
Launch Template, empty or invalid AMI value, pagination failure, permission
error or any AWS API error causes the invocation to fail before the first
`DeregisterImage`.

An image is eligible only when all conditions hold:

- owner is `self`;
- `ghr:managed=runner-ami-release`;
- AMI name starts with `github-runner-ubuntu-resolute-amd64-` or
  `github-runner-ubuntu-resolute-arm64-`;
- state is `available`;
- `CreationDate < T - 168 hours` using a strict UTC comparison;
- it is absent from active, previous, recovery and both resolved default
  Launch Templates.

The rule treats `candidate`, `passed` and `failed` identically. Active,
previous and recovery generations remain protected regardless of age; the
design does not promise to keep every image promoted during the last seven
days.

Deletion records the image's snapshot IDs, calls `DeregisterImage` with
`DeleteAssociatedSnapshots=false`, then awaits every explicit `DeleteSnapshot`
call. If `DeregisterImage` returns an unknown result, the housekeeper does not
retry it: for at most 120 seconds it polls `DescribeImages` until the AMI is
absent or no longer `available`. If that cannot be confirmed, it leaves every
snapshot untouched and returns failure. It MUST NOT issue any `DeleteSnapshot`
while deregistration remains unconfirmed.
A shared/in-use or already-absent snapshot is recorded as retained/skipped and
does not block other snapshots. Other deletion failures are logged before the
invocation returns failure. Dry-run performs the same selection and reports
the same candidate set without mutating resources.

The initial release has no durable deletion journal. Process loss after AMI
deregistration is confirmed but before every snapshot deletion completes can
leave orphaned snapshots that a later image enumeration cannot rediscover.
Automatic cross-invocation recovery for that interval is not guaranteed and
requires a separate journal or tagged snapshot sweep; until then, operators
must discover and remove such snapshots manually.

## Trigger And Rollout

`ami-release.yml` schedules both independent architecture jobs with
`37 2 * * 1`. Manual dispatch selects `all`, `amd64` or `arm64`. Build
concurrency is scoped to `runner-ami-build-<architecture>` with
`cancel-in-progress=false`: one build may run and one may remain pending for
each architecture; a newer duplicate dispatch can replace that pending build
under GitHub's concurrency semantics. No build in one architecture blocks the
other architecture. A failure in one architecture never cancels or blocks the
other.

Auto-promotion is controlled by two repository variables, both configured
`true` during workflow setup:

- `AMI_AUTO_PROMOTE_AMD64`
- `AMI_AUTO_PROMOTE_ARM64`

The reusable build workflow invokes promotion only when the matching variable
is exactly `true`; a missing value or explicit `false` pauses that architecture
without affecting build and validation. The
`runner-ami-production-<architecture>` environments retain their
default-branch deployment restriction but do not require human approval.
Both automatic and manual promotion target the same environment. Rollback
remains an explicit manual command.

Rollout order:

1. Apply the moved active parameters, create previous channels, IAM roles,
   profiles and zero-ingress security groups.
2. Configure both `runner-ami-production-<architecture>` environments, then
   verify each restricts deployments to the default branch and has no required
   reviewer or wait timer.
3. Verify the plan has no active parameter replacement and both previous values
   equal their active value.
4. Set both auto-promotion switches to `true` and enable scheduled build and
   final-image validation.
5. Run both architecture builds once; each successful validator automatically
   promotes its candidate independently.
6. Observe real runner jobs and verify the rollback workflow is ready.
7. Run housekeeper dry-run for at least one complete weekly cycle. Review the
   complete candidate set and confirm every candidate is outside the protected
   channel and Launch Template set.
8. Enable live cleanup.
