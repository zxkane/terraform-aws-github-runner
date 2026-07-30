# Automated Runner AMI Release Test Cases

## Static Configuration

| ID | Scenario | Expected result |
|---|---|---|
| TC-AMI-001 | Format and validate both release Packer templates | Both pass |
| TC-AMI-002 | Inspect builder transport | SSH communicator uses `session_manager`; no public IP; explicit private subnet, instance profile and zero-ingress SG |
| TC-AMI-003 | Inspect builder and image metadata/storage | Builder requires IMDSv2; AMI has `ImdsSupport=v2.0`; boot snapshot encryption is enabled |
| TC-AMI-003A | Inspect the Packer encryption path | Encrypted launch mapping is enabled and `encrypt_boot` is unset, so no `CopyImage`/temporary AMI cleanup permission is required |
| TC-AMI-004 | Inspect release workflows | Every runner-backed job uses GitHub-hosted `ubuntu-24.04`; caller jobs invoke only checked local reusable workflows |
| TC-AMI-005 | Inspect workflow permissions and actions | Baseline is `contents: read`; promotion additionally has `actions: read`; AWS jobs have job-scoped `id-token: write`; every action uses a full SHA |
| TC-AMI-006 | Manual release selects `all`, `amd64` or `arm64` | Only requested independent jobs run |
| TC-AMI-007 | Inspect weekly trigger | Cron is exactly `37 2 * * 1`; both architecture callers are enabled |
| TC-AMI-008 | Inspect channel writer concurrency | Per-architecture promote and rollback group matches and has `cancel-in-progress: false` |
| TC-AMI-009 | Inspect default rollout configuration | Both architecture auto-promotion switches default to disabled |
| TC-AMI-010 | Scan workflow outputs and artifacts | AMI/account identifiers are masked before replay and no raw Packer manifest is uploaded |
| TC-AMI-011 | Evaluate build-role IAM and Session Manager transport | Resource creation/mutation requires managed tags, launch inputs are scoped, Packer can use `AWS-StartPortForwardingSession`, and session cleanup is limited to the caller's sessions |
| TC-AMI-012 | Evaluate Packer create-time permissions | Build role can create and tag only managed temporary key pairs, instances, volumes, network interfaces, AMIs and snapshots required by both templates |
| TC-AMI-013 | Set `imds_support = "v2.0"` on the final AMI | Build role permits `ModifyImageAttribute` only for managed release images |
| TC-AMI-014 | Inspect source and package selection | Both Packer sources use the exact Canonical owner/name/storage/virtualization filters with `most_recent=true`, record `Base_AMI_Name`, refresh package metadata, and enforce the documented major/channel contract |
| TC-AMI-015 | Inspect promotion and rollback job timeout budgets | Each job timeout exceeds the sum of maximum sequential phase deadlines on its longest compensation path by at least 60 seconds |

## Candidate Build And Validation

| ID | Scenario | Expected result |
|---|---|---|
| TC-AMI-101 | Build amd64 attempt | Available x86_64 AMI has exact managed, release_id, architecture, revision and `candidate` tags |
| TC-AMI-102 | Build arm64 attempt | Available arm64 AMI has the same exact provenance contract |
| TC-AMI-103 | Retry the same GitHub run | `run_attempt` changes release_id, so candidates do not collide |
| TC-AMI-104 | Launch validator | On-Demand instance has no public IP/ingress, IMDSv2-only metadata, metadata tags enabled and terminate-on-shutdown |
| TC-AMI-105 | Boot validator with `ghr:ami_validation=true` | Baked startup exits before normal runner template and before production SSM/token reads |
| TC-AMI-106 | Inspect validator role | It has managed-node messaging but no `ssm:GetParameter*` or `kms:Decrypt` |
| TC-AMI-107 | Validate common tools | Node 24, Bun, Docker, AWS CLI v2, GitHub CLI, runner and Playwright Chromium pass |
| TC-AMI-108 | Validate amd64 browsers | Playwright Chromium and Google Chrome both start headlessly |
| TC-AMI-109 | Validate arm64 browsers | Playwright Chromium starts and Google Chrome executable is absent |
| TC-AMI-110 | Validate apt state | No regular file remains below `/var/lib/apt/lists` |
| TC-AMI-111 | Read IMDS without token | Request fails; token-authenticated architecture and instance data match expectations |
| TC-AMI-112 | Run Command returns `InvocationDoesNotExist`, Pending, InProgress or Delayed | Polling continues with bounded backoff before deadline |
| TC-AMI-113 | Run Command returns a non-Success terminal or unknown state | Candidate becomes `failed`; channels are untouched |
| TC-AMI-114 | Run Command exceeds 20-minute deadline | Candidate becomes `failed`; channels are untouched |
| TC-AMI-115 | All assertions pass | Candidate tag becomes `passed` only after terminal Success |
| TC-AMI-116 | Workflow succeeds, fails or receives a normal cancellation | Cleanup attempts validator termination; if cleanup is interrupted or force-cancelled after user data executes, scheduled shutdown terminates the validator within two hours, but cleanup does not claim that fallback when launch is unconfirmed |
| TC-AMI-117 | amd64 build fails | arm64 job continues independently, and vice versa |
| TC-AMI-118 | Validator does not register online with Systems Manager within 10 minutes | Validation fails, candidate becomes `failed`, and instance cleanup runs without sending Run Command |
| TC-AMI-119 | Inspect validator launch | `RunInstances` uses exact client token `ghr-validator-<release_id>-<architecture>` and instance/volume tags include managed, validator role, release and architecture |
| TC-AMI-120 | `RunInstances` applies but its response is lost; the first complete lookup is empty and a later lookup exposes the instance | The launch marker selects `LAUNCH_UNKNOWN`; cleanup repeatedly fully paginates exact validator tag/state filters for its full 120-second phase, deduplicates by InstanceId, terminates each discovered ID at most once, and never retries launch |
| TC-AMI-121 | Any validator AWS request hangs | The request is killed within 30 seconds or the shorter remaining phase deadline; cleanup has its own 120-second deadline |
| TC-AMI-122 | `InvocationDoesNotExist` retry would sleep beyond the validation deadline | Sleep is truncated to the remaining time and validation fails at the deadline |
| TC-AMI-123 | Validation fails while AWS prevents the failed tag write | Job fails, channels stay untouched and the AMI remains non-`passed`, so candidate selection rejects it |
| TC-AMI-124 | Run Command succeeds but the one `passed` mutation or its read-back remains unknown | Build job fails and auto-promotion is skipped; no conflicting `failed` mutation is sent; final tag may be `candidate` or `passed` |
| TC-AMI-125 | `LAUNCH_UNKNOWN` cleanup observes no matching ID for its entire deadline | Cleanup ends `UNCONFIRMED_LAUNCH`; the job fails and does not claim termination, while the two-hour user-data shutdown remains only a fallback |
| TC-AMI-126 | `KNOWN` fallback lookup cannot complete or one unique ID termination fails | Cleanup and the job fail; an ambiguous termination is not retried |
| TC-AMI-127 | `KNOWN` local and fallback IDs contain duplicates | Lookup completes, each unique InstanceId is terminated exactly once, and successful terminate responses complete cleanup without terminal-state polling |
| TC-AMI-128 | Packer exits while one or more exact tagged builder instances remain | A fully paginated lookup validates and deduplicates every ID, attempts each termination once with SDK retries disabled, and the cleanup phase ends within 120 seconds |

## Candidate Selection

| ID | Scenario | Expected result |
|---|---|---|
| TC-AMI-201 | Query exact release_id and architecture | Owner, managed, `ghr:validation_status=passed`, architecture and available-state filters are applied; selected revision equals exact run-attempt `head_sha` |
| TC-AMI-202 | Query returns no image | Promotion fails before channel reads/writes |
| TC-AMI-203 | Query returns multiple images | Promotion fails; it never selects newest/arbitrary image |
| TC-AMI-204 | Candidate tag is `candidate`, `failed`, missing or malformed | Promotion fails before channel writes |
| TC-AMI-205 | Candidate owner, architecture or revision is invalid | Promotion fails before channel writes |
| TC-AMI-206 | Candidate is at least 168 hours old | Promotion fails before channel writes |
| TC-AMI-207 | Dispatch input resembles an AMI ID | Workflow schema rejects it because no AMI input exists |
| TC-AMI-208 | Candidate `CreationDate` equals frozen promotion time T minus exactly 168 hours | Promotion fails before channel writes; the gate does not use a later wall clock or release ID |
| TC-AMI-209 | Candidate lookup returns one match on its first page and another on a later page, or a later page fails | Every page is requested; promotion rejects multiple/error results before any SSM channel read or write |

## Promotion

| ID | Scenario | Expected result |
|---|---|---|
| TC-AMI-301 | Promote valid C from `(A,P)` | Final channels are `(C,A)` and default LT resolves to C |
| TC-AMI-302 | Promote when `C == A` | No parameter write; P remains unchanged; LT is verified |
| TC-AMI-303 | Previous write fails with unchanged state | Final channels remain `(A,P)` and workflow fails |
| TC-AMI-304 | Previous write times out after applying | Deadline-bounded read-back recognizes `(A,A,P)` and continues without repeating the write |
| TC-AMI-305 | After a destructive write, a channel becomes unreadable or changes outside `(A,P,P)`, `(A,A,P)`, `(C,A,P)` | Workflow performs no further write and ends `COMPENSATION_FAILED` |
| TC-AMI-306 | Active write fails or times out | Observed state is reconciled, then compensation restores `(A,P)` |
| TC-AMI-307 | Parameter or LT resolution does not converge within 120 seconds | Compensation restores and verifies `(A,P)` |
| TC-AMI-308 | Active compensation succeeds but previous compensation fails | Workflow ends `COMPENSATION_FAILED` with observed state logged |
| TC-AMI-309 | Force-cancel before active write, then rerun | Rerun safely reaches `(C,A)` |
| TC-AMI-310 | Force-cancel after active write, then rerun | Rerun recognizes active C, leaves previous A and succeeds |
| TC-AMI-311 | Start two promotes for same architecture | Second run queues and cannot cancel the first |
| TC-AMI-312 | Promote amd64 and arm64 concurrently | Both succeed using independent groups and channels |
| TC-AMI-313 | Re-promote active C after it becomes 168 hours old | C==A short-circuits before the new-candidate age gate and succeeds without writes |
| TC-AMI-314 | Any normal or compensation write returns success, timeout or an unrecognized response | HTTP success alone is insufficient; each phase polls for at most its own 120 seconds, target classifies applied, source-through-deadline classifies unchanged, and unreadable/third value causes no blind retry |
| TC-AMI-315 | Channels are `(A,A,P)` and active becomes C before this invocation writes active | `(C,A,P)` is recognized as the desired state; the active write is skipped and full-tuple/LT verification decides success |
| TC-AMI-316 | Compensation starts from `(A,P,P)`, `(A,A,P)`, `(C,A,P)` or any other tuple | The three protocol tuples respectively require zero writes, previous-only restore, or active-then-previous restore; any other/unreadable tuple is not overwritten |
| TC-AMI-317 | Promote from `(A,P,R)` where R differs from P | Workflow writes and confirms `recovery=P` before any previous/active write; write order is recovery, previous, active |
| TC-AMI-318 | Recovery write is unchanged, unknown or drifts before a promotion mutation | Promotion fails before previous/active writes; the original `(A,P)` remains protected |
| TC-AMI-319 | Housekeeper freezes protection while promotion is at `(A,A,P)` | P remains protected through recovery even when older than 168 hours and absent from active/previous/LT |
| TC-AMI-320 | Force-cancel after recovery/previous writes, then rerun | New invocation captures the observed active/previous, safely replaces recovery for its own compensation source, and reaches its candidate without claiming restoration to the earlier invocation |
| TC-AMI-321 | Promotion succeeds | Final tuple is `(C,A,P)`; recovery is retained until a later channel mutation safely overwrites it |
| TC-AMI-322 | Recovery is confirmed, then active or previous drifts before the first destructive write | Full-tuple read stops with `EXTERNAL_DRIFT`, issues no previous/active or compensation write, and does not report `COMPENSATION_FAILED` |
| TC-AMI-323 | Promotion is at `(A,A,P)` and recovery changes to X before the active write | Full-tuple read observes `(A,A,X)`, performs no active or compensation write, and ends `COMPENSATION_FAILED` |
| TC-AMI-324 | Final promotion convergence observes `(C,A,X)` | It cannot succeed on the `(C,A)` projection; no further write is issued and the result is `COMPENSATION_FAILED` |
| TC-AMI-325 | Promotion starts with `R=P`, or with `P=A` | It skips the corresponding redundant recovery or previous mutation, still performs a full-tuple read, and reaches `(C,A,P)` |
| TC-AMI-326 | A channel AWS request hangs or a mutation result is transport-ambiguous | Request ends within min(30 seconds, phase remaining); no request starts at the deadline and no ambiguous mutation is retried |

## Rollback

| ID | Scenario | Expected result |
|---|---|---|
| TC-AMI-401 | Roll back valid `(A,P)` | Active becomes P, previous stays P and LT resolves to P |
| TC-AMI-402 | Roll back when `A == P` | Idempotent no-op with LT verification |
| TC-AMI-403 | Previous is missing, unavailable, wrong-owner or wrong-architecture | Abort without writing active |
| TC-AMI-404 | Rollback active write remains at A through its deadline | `(A,P,A)` is treated as not applied; no compensation write occurs and the workflow fails normally |
| TC-AMI-405 | Rollback reaches `(P,P,A)` but channel/LT verification fails | Active is restored and verified as A; previous remains P and recovery remains A |
| TC-AMI-406 | Active restore fails, a channel is unreadable or a tuple other than `(A,P,A)`/`(P,P,A)` is observed | Workflow ends `COMPENSATION_FAILED`; the unexpected state is not overwritten |
| TC-AMI-407 | Promote and rollback start for same architecture | Shared concurrency serializes both workflows |
| TC-AMI-408 | Roll back from `(A,P,R)` where R differs from A | Workflow writes and confirms `recovery=A` before writing active; final tuple is `(P,P,A)` |
| TC-AMI-409 | Housekeeper freezes protection while rollback is at `(P,P,A)` | A remains protected through recovery and rollback compensation can restore it |
| TC-AMI-410 | Rollback recovery write cannot be confirmed | Rollback fails before active is written and channels remain `(A,P)` |
| TC-AMI-411 | Rollback is at `(A,P,A)` or `(P,P,A)` and recovery changes to X | A full-tuple read prevents success or another write and ends `COMPENSATION_FAILED` after a destructive write |
| TC-AMI-412 | Rollback starts with `R=A` | It skips the redundant recovery mutation, confirms `(A,P,A)`, and continues normally |

## Terraform Migration And IAM

| ID | Scenario | Expected result |
|---|---|---|
| TC-AMI-501 | Plan active channel moves | Exact nested addresses move to root resources with no destroy/create |
| TC-AMI-502 | Apply migration | Active parameter names, ARNs, types and values remain unchanged |
| TC-AMI-503 | Initialize previous channels | Each value exactly equals the corresponding pre-migration active value |
| TC-AMI-504 | Change channel value outside Terraform | Subsequent plan does not revert it |
| TC-AMI-505 | Plan resource destruction | `prevent_destroy` blocks all six channel resources |
| TC-AMI-506 | Inspect Launch Templates | Both still use `resolve:ssm:<root-active-parameter-arn>` |
| TC-AMI-507 | Inspect build OIDC trust | Exact audience and default-branch subject only |
| TC-AMI-508 | Inspect promotion OIDC trusts | Each architecture role trusts only its exact production environment subject |
| TC-AMI-509 | Attempt build from non-default branch token | AssumeRoleWithWebIdentity is denied |
| TC-AMI-510 | Attempt promotion from branch subject or wrong environment | AssumeRoleWithWebIdentity is denied |
| TC-AMI-511 | Inspect build policy | It cannot put active/previous/recovery parameters |
| TC-AMI-512 | Inspect promotion policies | Each can read and write only its architecture's three channels and cannot create/deregister AMIs |
| TC-AMI-513 | Plan recovery channel creation | Both exact recovery parameters are `aws:ec2:image`, initialize from pre-migration active and have `prevent_destroy` plus `ignore_changes=[value]` |
| TC-AMI-514 | Inspect housekeeper channel configuration | Exactly six names are derived from the same channel locals in per-architecture active, previous, recovery order; no wildcard is used |
| TC-AMI-515 | Inspect validator cleanup IAM | Build role can describe instances and terminate only release-managed validator instances selected by exact cleanup tags |
| TC-AMI-516 | Inspect housekeeper execution role | Dedicated role reads exactly six channel parameters, has only required image/LT describe and tagged release-image/snapshot cleanup permissions, and has no SSM write, image creation, instance lifecycle or IAM mutation permission |
| TC-AMI-517 | Inspect every release AMI snapshot and housekeeper delete policy | Each snapshot has the six release tags from creation; tagged snapshots are deletable, an untagged snapshot is denied, and no unconditional `DeleteSnapshot` allow exists |

## Housekeeper

| ID | Scenario | Expected result |
|---|---|---|
| TC-AMI-601 | Active, previous, recovery and both default LTs reference images | All referenced images are protected regardless of age |
| TC-AMI-602 | Explicit SSM parameter is missing, invalid or unreadable | Invocation rejects before any deregistration |
| TC-AMI-603 | Wildcard discovery or pagination fails | Invocation rejects before any deregistration |
| TC-AMI-604 | Requested LT `$Default` is missing, returns multiple versions, or its `ResolveAlias=true` ImageId is invalid, unresolvable or unreadable | Invocation rejects before any deregistration |
| TC-AMI-605 | Managed unreferenced image is exactly 168 hours old | Strict boundary retains it |
| TC-AMI-606 | Managed unreferenced image is older than 168 hours | Dry-run reports it; live mode deregisters it |
| TC-AMI-607 | Old image lacks the managed release tag or expected immutable name prefix | It is never considered for deletion |
| TC-AMI-608 | AMI owns multiple snapshots | Every explicit deletion promise is awaited before return |
| TC-AMI-609 | Snapshot is shared/in-use or already absent | Result is retained/skipped and remaining snapshots continue |
| TC-AMI-610 | Other snapshot deletion fails | Error is logged and invocation rejects after attempted work completes |
| TC-AMI-611 | Dry-run and live selection receive identical input | Candidate sets are identical; dry-run performs no mutations |
| TC-AMI-612 | Candidate-tagged AMI is older than 168 hours and unprotected | It is eligible exactly like an equally old failed/passed image; no in-progress exemption exists |
| TC-AMI-613 | Multiple images cross the age boundary during one invocation | Injected evaluation time T is used for every image, so results cannot vary by processing order |
| TC-AMI-614 | Candidate AMI enumeration spans pages or a later page fails | Every page uses the one frozen protection set; a later-page failure occurs before any deregistration |
| TC-AMI-615 | `DeregisterImage` returns an unknown result after applying | No deregistration retry occurs; snapshots are deleted only after read-back confirms the AMI is absent/not available |
| TC-AMI-616 | `DeregisterImage` result remains unreadable or available for 120 seconds | Invocation fails and no snapshot deletion is attempted |
| TC-AMI-617 | Recovery parameter is missing, unreadable, empty or malformed | Invocation fails before candidate enumeration or deregistration |
| TC-AMI-618 | A well-formed recovery ID no longer resolves to an image | It is a harmless protection-set no-match and does not block other eligible cleanup |
| TC-AMI-619 | Channel values change while protection is resolved | Explicit values are read per architecture in active, previous, recovery order, so a compensation source is observed before or after the writer's recovery-first transition |
| TC-AMI-620 | Active equals previous while recovery references a different old image | Housekeeper still performs all three reads and protects every well-formed observed value; it never skips recovery |
| TC-AMI-621 | Deregister a selected image | Request explicitly sets `DeleteAssociatedSnapshots=false`; snapshots are deleted only by the subsequent individually awaited calls |
| TC-AMI-622 | Any housekeeper AWS request hangs or an EC2 mutation result is transport-ambiguous | Request ends within min(30 seconds, phase remaining); ambiguous mutations are not retried and follow only documented reconciliation |

The initial release does not claim automatic recovery if the Lambda process
stops after confirmed AMI deregistration but before all snapshot deletions
finish. That crash interval is a documented residual risk, not a behavior
covered by the in-invocation deletion tests.

## Production Gates

| ID | Scenario | Expected result |
|---|---|---|
| TC-AMI-701 | First scheduled rollout | Both architectures build and validate; neither auto-promotes |
| TC-AMI-702 | Manual promotion or rollback | Correct architecture environment and default-branch restriction apply |
| TC-AMI-703 | Only amd64 gate is complete, its protected variable is true, and its environment reviewers are removed while default-branch restriction remains | amd64 may auto-promote through that environment; arm64 remains build-and-validate only |
| TC-AMI-704 | Fewer than three consecutive clean cycles or missing workload/drill evidence | Corresponding switch remains disabled |
| TC-AMI-705 | Housekeeper first full weekly cycle | `dryRun=true`; candidate logs are reviewed before live mode |
| TC-AMI-706 | Manual promotion reaches real fleet | New instances resolve the promoted AMI while already-running instances remain unchanged |
| TC-AMI-707 | Rollback drill | New instances resolve previous; previous remains unchanged; forward promotion still succeeds |
| TC-AMI-708 | Disable auto-promotion for one architecture | Variable is set false before required reviewers are restored; later builds validate only and manual promotion still targets the protected environment |
