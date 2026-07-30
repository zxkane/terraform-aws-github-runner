#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$REPO_ROOT/$1" ]] || fail "missing $1"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  rg -q -- "$pattern" "$REPO_ROOT/$file" || fail "$message"
}

workflows=(
  ".github/workflows/ami-build.yml"
  ".github/workflows/ami-release.yml"
  ".github/workflows/ami-promote.yml"
  ".github/workflows/ami-rollback.yml"
  ".github/workflows/ami-release-checks.yml"
)

assert_file "deployments/shared-runners/scripts/cleanup-release-builders.sh"
assert_file "deployments/shared-runners/scripts/cleanup-release-builders.test.sh"
assert_file "deployments/shared-runners/scripts/cleanup-release-validators.sh"
assert_file "deployments/shared-runners/scripts/cleanup-release-validators.test.sh"

for workflow in "${workflows[@]}"; do
  assert_file "$workflow"
  if ! rg -q 'runs-on: ubuntu-24\.04' "$REPO_ROOT/$workflow" &&
    ! rg -q 'uses: \./\.github/workflows/' "$REPO_ROOT/$workflow"; then
    fail "$workflow must use GitHub-hosted ubuntu-24.04 or a checked local reusable workflow"
  fi
  if rg -q 'runs-on:.*self-hosted' "$REPO_ROOT/$workflow"; then
    fail "$workflow must never use self-hosted runners"
  fi

  while IFS= read -r use; do
    [[ "$use" == ./* ]] && continue
    [[ "$use" =~ @[0-9a-f]{40}$ ]] || fail "$workflow contains an unpinned action: $use"
  done < <(sed -nE 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*([^#[:space:]]+).*$/\1/p' "$REPO_ROOT/$workflow")
done

assert_contains ".github/workflows/ami-release.yml" "cron: ['\"]37 2 \\* \\* 1['\"]" \
  "weekly release cron must be Monday 02:37 UTC"
assert_contains ".github/workflows/ami-release.yml" 'architecture:' \
  "manual release must expose architecture selection"
assert_contains ".github/workflows/ami-build.yml" 'workflow_call:' \
  "per-architecture build must be reusable"
assert_contains ".github/workflows/ami-build.yml" 'PACKER_GITHUB_API_TOKEN:' \
  "Packer plugin downloads must authenticate to GitHub"
assert_contains ".github/workflows/ami-build.yml" 'AMI_SOURCE_OWNER_ID:' \
  "Packer builds must receive the trusted Canonical owner without committing an account ID"
assert_contains ".github/workflows/packer-build.yml" 'PKR_VAR_source_ami_owner:' \
  "existing Packer checks must supply the now-required source owner variable"
assert_contains ".github/workflows/ami-build.yml" 'SESSION_MANAGER_PLUGIN_SHA256:' \
  "Session Manager plugin downloads must be checksum verified"
assert_contains ".github/workflows/ami-promote.yml" 'cancel-in-progress: false' \
  "promotion must queue channel writers"
assert_contains ".github/workflows/ami-rollback.yml" 'cancel-in-progress: false' \
  "rollback must queue channel writers"
assert_contains ".github/workflows/ami-promote.yml" 'runner-ami-production-' \
  "promotion must bind an architecture environment"
assert_contains ".github/workflows/ami-rollback.yml" 'runner-ami-production-' \
  "rollback must bind an architecture environment"

for image_dir in images/ubuntu-resolute images/ubuntu-resolute-arm64; do
  template="$image_dir/github_agent.ubuntu.pkr.hcl"
  assert_contains "$template" 'communicator[[:space:]]*=[[:space:]]*"ssh"' \
    "$image_dir must use the SSH communicator"
  assert_contains "$template" 'ssh_interface[[:space:]]*=[[:space:]]*"session_manager"' \
    "$image_dir must connect through Session Manager"
  assert_contains "$template" 'associate_public_ip_address[[:space:]]*=[[:space:]]*false' \
    "$image_dir must not assign a public IP"
  assert_contains "$template" 'encrypted[[:space:]]*=[[:space:]]*true' \
    "$image_dir must launch an encrypted root volume"
  if rg -q 'encrypt_boot[[:space:]]*=' "$REPO_ROOT/$template"; then
    fail "$image_dir must not trigger Packer's redundant AMI copy-encryption path"
  fi
  assert_contains "$template" 'ghr:release_id' \
    "$image_dir must tag release identity"
  assert_contains "$template" 'ghr:validation_status' \
    "$image_dir must tag candidate state"
  assert_contains "$template" 'snapshot_tags[[:space:]]*=[[:space:]]*merge\(' \
    "$image_dir must apply tags to release snapshots"
  assert_contains "$template" 'local\.release_tags' \
    "$image_dir snapshots must inherit all six release tags"
  assert_contains "$template" 'owners[[:space:]]*=[[:space:]]*\[var\.source_ami_owner\]' \
    "$image_dir must scope source discovery to the configured Canonical owner"
done

terraform_file="deployments/shared-runners/ami-release.tf"
assert_file "$terraform_file"
build_policy="$(
  sed -n \
    '/^data "aws_iam_policy_document" "ami_build" {$/,/^resource "aws_iam_role_policy" "ami_build" {$/p' \
    "$REPO_ROOT/$terraform_file"
)"
if rg -q '"ec2:(DeregisterImage|DeleteSnapshot)"' <<<"$build_policy"; then
  fail "build role must not delete AMIs or snapshots"
fi
assert_contains "$terraform_file" 'module\.runners\.module\.runners\["linux-amd64"\]\.aws_ssm_parameter\.runner_ami_id\[0\]' \
  "amd64 active parameter move must use the exact old address"
assert_contains "$terraform_file" 'module\.runners\.module\.runners\["linux-arm64"\]\.aws_ssm_parameter\.runner_ami_id\[0\]' \
  "arm64 active parameter move must use the exact old address"
assert_contains "$terraform_file" 'prevent_destroy[[:space:]]*=[[:space:]]*true' \
  "channel parameters must prevent destroy"
assert_contains "$terraform_file" 'ignore_changes[[:space:]]*=[[:space:]]*\[value\]' \
  "Terraform must ignore workflow-owned channel values"
assert_contains "$terraform_file" 'runner-ami-promotion-amd64' \
  "amd64 promotion role must be architecture scoped"
assert_contains "$terraform_file" 'runner-ami-promotion-arm64' \
  "arm64 promotion role must be architecture scoped"
if rg -q 'AmazonSSMManagedInstanceCore' "$REPO_ROOT/$terraform_file"; then
  fail "validator role must not inherit Parameter Store read permissions"
fi
assert_contains "$terraform_file" 'ssmmessages:OpenControlChannel' \
  "builder and validator must use a minimal managed-node messaging policy"
assert_contains "$terraform_file" '"ssm:GetParameter"' \
  "promotion roles must read their architecture channels"
assert_contains "$terraform_file" '"ssm:PutParameter"' \
  "promotion roles must write their architecture channels"
assert_contains "$terraform_file" 'aws_ssm_parameter\.runner_ami_active\[each\.key\]\.arn' \
  "promotion role channel permissions must use the architecture active ARN"
assert_contains "$terraform_file" 'aws_ssm_parameter\.runner_ami_previous\[each\.key\]\.arn' \
  "promotion role channel permissions must use the architecture previous ARN"
assert_contains "$terraform_file" 'aws_ssm_parameter\.runner_ami_recovery\[each\.key\]\.arn' \
  "promotion role must protect the architecture recovery channel"
assert_contains "$terraform_file" 'local\.ami_channel_names\[architecture\]\.recovery' \
  "housekeeper must protect the durable compensation source"
assert_contains "$terraform_file" 'ec2:ResourceTag/ghr:managed' \
  "housekeeper deletion permissions must require the release-managed tag"
assert_contains "$terraform_file" 'lambda_ami_policy_json[[:space:]]*=[[:space:]]*data\.aws_iam_policy_document\.release_ami_housekeeper\.json' \
  "release housekeeper must override the generic account-wide policy"
assert_contains "$terraform_file" 'lambda_timeout[[:space:]]*=[[:space:]]*900' \
  "release housekeeper must use the full Lambda timeout"
assert_contains "$terraform_file" 'ec2:InstanceProfile' \
  "build role instance mutations must be scoped to its instance profiles"
assert_contains "$terraform_file" 'aws:RequestTag/ghr:managed' \
  "build role resource creation must require the managed release tag"
assert_contains "$terraform_file" 'AWS-StartPortForwardingSession' \
  "Packer must be allowed to use its Session Manager port-forwarding document"
assert_contains "$terraform_file" '"ec2:CreateKeyPair"' \
  "Packer must be allowed to create its managed temporary key pair"
assert_contains "$terraform_file" '"ec2:ModifyImageAttribute"' \
  "Packer must be allowed to set final AMI IMDSv2 support"
assert_contains "$terraform_file" 'key-pair/github-runner-ami-' \
  "Packer key-pair permissions must be restricted to its temporary name prefixes"
assert_contains "$terraform_file" 'network-interface/\*' \
  "Packer must be allowed to tag launch-created network interfaces"
# shellcheck disable=SC2016 # Match the literal IAM policy variable.
assert_contains "$terraform_file" 'session/\$\$\{aws:userid\}-\*' \
  "build role must manage only sessions created by its own role session"
assert_contains "images/ubuntu-resolute/github_agent.ubuntu.pkr.hcl" '"ghr:ami_role"[[:space:]]*=[[:space:]]*"builder"' \
  "amd64 Packer builder instances must carry the IAM scope tag"
assert_contains "images/ubuntu-resolute-arm64/github_agent.ubuntu.pkr.hcl" '"ghr:ami_role"[[:space:]]*=[[:space:]]*"builder"' \
  "arm64 Packer builder instances must carry the IAM scope tag"
assert_contains "deployments/shared-runners/scripts/03-deploy.sh" "node_major.*24" \
  "deployment must require Node.js 24 before packaging Lambda functions"
assert_contains "deployments/shared-runners/scripts/03-deploy.sh" 'corepack yarn install --immutable' \
  "deployment must install locked Lambda dependencies before packaging"
assert_contains "deployments/shared-runners/scripts/03-deploy.sh" 'corepack yarn dist' \
  "deployment must build Lambda artifacts before planning"
assert_contains "deployments/shared-runners/scripts/validate-release-ami.sh" \
  'AMI_REGISTRATION_DEADLINE_SECONDS:-600' \
  "validator Systems Manager registration must have a ten-minute deadline"
assert_contains ".github/workflows/ami-build.yml" 'if: always\(\)' \
  "build workflow must always attempt validator instance cleanup"
assert_contains "deployments/shared-runners/scripts/cleanup-release-builders.sh" \
  'Name=tag:ghr:ami_role,Values=builder' \
  "build workflow must clean up exact Packer builder instances"
# shellcheck disable=SC2016 # Match the literal workflow shell variable.
assert_contains "deployments/shared-runners/scripts/cleanup-release-builders.sh" \
  'Name=tag:ghr:release_id,Values=\$RELEASE_ID' \
  "builder cleanup must be scoped to the exact release attempt"
assert_contains ".github/workflows/ami-build.yml" 'cleanup-release-builders\.sh' \
  "workflow builder cleanup must use the tested bounded state machine"
assert_contains ".github/workflows/ami-build.yml" 'VALIDATOR_INSTANCE_ID_FILE' \
  "validator script and workflow cleanup must share an instance ID file"
assert_contains ".github/workflows/ami-build.yml" 'VALIDATOR_LAUNCH_MARKER_FILE' \
  "validator script and workflow cleanup must share a launch-attempt marker"
assert_contains "deployments/shared-runners/scripts/cleanup-release-validators.sh" \
  'Name=tag:ghr:ami_role,Values=validator' \
  "workflow cleanup must discover validators whose launch response was lost"
assert_contains ".github/workflows/ami-build.yml" 'cleanup-release-validators\.sh' \
  "workflow cleanup must use the tested validator cleanup state machine"
# shellcheck disable=SC2016 # Match the literal validator client-token argument.
assert_contains "deployments/shared-runners/scripts/validate-release-ami.sh" \
  '--client-token "\$validator_client_token"' \
  "validator launches must use an EC2 idempotency token"
assert_contains "deployments/shared-runners/scripts/validate-release-ami.sh" \
  'VALIDATOR_LAUNCH_MARKER_FILE' \
  "validator must persist launch intent before RunInstances"
assert_contains "deployments/shared-runners/scripts/ami-channel.sh" \
  '--page-size[[:space:]]+100' \
  "candidate lookup must explicitly use AWS CLI pagination"
assert_contains ".github/workflows/ami-promote.yml" 'timeout-minutes:[[:space:]]*(4[5-9]|[5-9][0-9]|[1-9][0-9]{2,})' \
  "promotion timeout must cover the longest compensation path"
assert_contains ".github/workflows/ami-rollback.yml" 'timeout-minutes:[[:space:]]*(4[5-9]|[5-9][0-9]|[1-9][0-9]{2,})' \
  "rollback timeout must cover the longest compensation path"
assert_contains ".github/workflows/ami-build.yml" 'AMI_AUTO_PROMOTE_AMD64' \
  "amd64 auto-promotion must have an independent switch"
assert_contains ".github/workflows/ami-build.yml" 'AMI_AUTO_PROMOTE_ARM64' \
  "arm64 auto-promotion must have an independent switch"
assert_contains "lambdas/functions/ami-housekeeper/src/ami.ts" 'maxAttempts:[[:space:]]*1' \
  "housekeeper AMI mutations must disable automatic SDK retries"
assert_contains "lambdas/functions/ami-housekeeper/src/ami.ts" \
  'DeleteAssociatedSnapshots:[[:space:]]*false' \
  "housekeeper must keep snapshot deletion explicit"
assert_contains "$terraform_file" 'github-runner-ubuntu-resolute-amd64-\*' \
  "housekeeper candidates must match the immutable amd64 AMI name prefix"
assert_contains "$terraform_file" 'github-runner-ubuntu-resolute-arm64-\*' \
  "housekeeper candidates must match the immutable arm64 AMI name prefix"
# shellcheck disable=SC2016 # Match the literal build-script shell variable.
assert_contains "deployments/shared-runners/scripts/build-release-ami.sh" '-var "region=\$AWS_REGION"' \
  "release builds must pass the workflow region to Packer"

echo "PASS: automated AMI release static contract"
