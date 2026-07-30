#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-release-ami.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat >"$tmp_dir/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

service="${1:?}"
operation="${2:?}"
shift 2

case "$service:$operation" in
  ec2:describe-images)
    validation_status="candidate"
    release_id="123.1"
    if [[ "$AMI_VALIDATION_TEST_MODE" == "preflight-passed" ]]; then
      validation_status="passed"
    elif [[ "$AMI_VALIDATION_TEST_MODE" == "preflight-wrong-release" ]]; then
      release_id="999.1"
    elif [[ -f "$AMI_VALIDATION_TEST_TAG_STATE" ]]; then
      validation_status="$(<"$AMI_VALIDATION_TEST_TAG_STATE")"
      if [[ "$AMI_VALIDATION_TEST_MODE" == "tag-delayed" && "$validation_status" == "passed" ]]; then
        reads=0
        [[ ! -f "$AMI_VALIDATION_TEST_TAG_READS" ]] || reads="$(<"$AMI_VALIDATION_TEST_TAG_READS")"
        printf '%s\n' "$((reads + 1))" >"$AMI_VALIDATION_TEST_TAG_READS"
        ((reads >= 1)) || validation_status="candidate"
      fi
    fi
    cat <<JSON
{"Images":[{
  "ImageId":"ami-aaaaaaaaaaaaaaaaa",
  "State":"available",
  "Architecture":"x86_64",
  "ImdsSupport":"v2.0",
  "BlockDeviceMappings":[{"Ebs":{"Encrypted":true}}],
  "Tags":[
    {"Key":"ghr:managed","Value":"runner-ami-release"},
    {"Key":"ghr:release_id","Value":"$release_id"},
    {"Key":"ghr:architecture","Value":"amd64"},
    {"Key":"ghr:ami_role","Value":"builder"},
    {"Key":"ghr:source_revision","Value":"1111111111111111111111111111111111111111"},
    {"Key":"ghr:validation_status","Value":"$validation_status"}
  ]
}]}
JSON
    ;;
  ec2:run-instances)
    printf 'run:%s\n' "$*" >>"$AMI_VALIDATION_TEST_CALLS"
    if [[ "$AMI_VALIDATION_TEST_MODE" == "run-hang" ]]; then
      /bin/sleep 5
    fi
    printf 'i-aaaaaaaaaaaaaaaaa\n'
    ;;
  ec2:create-tags)
    printf 'tag:%s\n' "$*" >>"$AMI_VALIDATION_TEST_CALLS"
    if [[ "$*" == *"Value=passed"* ]]; then
      if [[ "$AMI_VALIDATION_TEST_MODE" != "passed-tag-unknown" ]]; then
        printf 'passed\n' >"$AMI_VALIDATION_TEST_TAG_STATE"
      fi
    elif [[ "$*" == *"Value=failed"* ]]; then
      printf 'failed\n' >"$AMI_VALIDATION_TEST_TAG_STATE"
    fi
    ;;
  ec2:terminate-instances)
    printf 'terminate:%s\n' "$*" >>"$AMI_VALIDATION_TEST_CALLS"
    ;;
  ssm:describe-instance-information)
    if [[ "$AMI_VALIDATION_TEST_MODE" == "registration-timeout" ]]; then
      printf 'None\n'
    else
      printf 'Online\n'
    fi
    ;;
  ssm:send-command)
    printf 'send-command\n' >>"$AMI_VALIDATION_TEST_CALLS"
    printf '11111111-1111-1111-1111-111111111111\n'
    ;;
  ssm:get-command-invocation)
    case "$AMI_VALIDATION_TEST_MODE" in
      invocation-missing-once | invocation-missing-deadline)
        count=0
        [[ ! -f "$AMI_VALIDATION_TEST_INVOCATION_STATE" ]] ||
          count="$(<"$AMI_VALIDATION_TEST_INVOCATION_STATE")"
        if ((count == 0)); then
          printf '1\n' >"$AMI_VALIDATION_TEST_INVOCATION_STATE"
          echo "InvocationDoesNotExist" >&2
          exit 255
        fi
        printf '{"Status":"Success","ResponseCode":0}\n'
        ;;
      success | tag-delayed | passed-tag-unknown)
        printf '{"Status":"Success","ResponseCode":0}\n'
        ;;
      terminal-failure)
        printf '{"Status":"Failed","ResponseCode":1,"StandardErrorContent":"validation failed"}\n'
        ;;
      *)
        printf '{"Status":"Pending","ResponseCode":-1}\n'
        ;;
    esac
    ;;
  *)
    echo "unexpected aws call: $service $operation $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$tmp_dir/aws"

cat >"$tmp_dir/sleep" <<'EOF'
#!/usr/bin/env bash
if [[ "${AMI_VALIDATION_TEST_REAL_SLEEP:-false}" == "true" ]]; then
  exec /bin/sleep "$@"
fi
EOF
chmod +x "$tmp_dir/sleep"

printf 'ami-aaaaaaaaaaaaaaaaa\n' >"$tmp_dir/ami-id"

run_validator() {
  local mode="$1"
  local registration_deadline="${2:-2}"
  local validation_deadline="${3:-2}"

  : >"$tmp_dir/calls"
  rm -f \
    "$tmp_dir/invocation-state" \
    "$tmp_dir/tag-state" \
    "$tmp_dir/tag-reads" \
    "$tmp_dir/validator-id" \
    "$tmp_dir/launch-attempted"

  PATH="$tmp_dir:$PATH" \
    ARCHITECTURE=amd64 \
    AWS_REGION=us-east-1 \
    RELEASE_ID=123.1 \
    SOURCE_REVISION=1111111111111111111111111111111111111111 \
    AMI_ID_FILE="$tmp_dir/ami-id" \
    AMI_VALIDATOR_INSTANCE_PROFILE=runner-ami-validator \
    AMI_VALIDATOR_SECURITY_GROUP_ID=sg-aaaaaaaaaaaaaaaaa \
    AMI_SUBNET_ID=subnet-aaaaaaaaaaaaaaaaa \
    VALIDATOR_INSTANCE_ID_FILE="$tmp_dir/validator-id" \
    VALIDATOR_LAUNCH_MARKER_FILE="$tmp_dir/launch-attempted" \
    AMI_REGISTRATION_DEADLINE_SECONDS="$registration_deadline" \
    AMI_VALIDATION_DEADLINE_SECONDS="$validation_deadline" \
    AMI_VALIDATION_POLL_SECONDS="${AMI_VALIDATION_POLL_SECONDS:-0.01}" \
    AMI_VALIDATION_AWS_CLI_TIMEOUT_SECONDS=1 \
    AMI_VALIDATION_TAG_DEADLINE_SECONDS=1 \
    AMI_VALIDATION_TEST_REAL_SLEEP="${AMI_VALIDATION_TEST_REAL_SLEEP:-false}" \
    AMI_VALIDATION_TEST_MODE="$mode" \
    AMI_VALIDATION_TEST_CALLS="$tmp_dir/calls" \
    AMI_VALIDATION_TEST_INVOCATION_STATE="$tmp_dir/invocation-state" \
    AMI_VALIDATION_TEST_TAG_STATE="$tmp_dir/tag-state" \
    AMI_VALIDATION_TEST_TAG_READS="$tmp_dir/tag-reads" \
    "$VALIDATOR"
}

run_validator invocation-missing-once
grep -q 'Value=passed' "$tmp_dir/calls" || fail "successful validation must tag the AMI passed"
if grep -q 'Value=failed' "$tmp_dir/calls"; then
  fail "successful validation must not tag the AMI failed"
fi
if grep -q '^terminate:' "$tmp_dir/calls"; then
  fail "validator script must leave termination to the tested workflow cleanup state machine"
fi
grep -q -- '--client-token ghr-validator-123.1-amd64' "$tmp_dir/calls" ||
  fail "validator launch must use a deterministic EC2 client token"
grep -q 'Key=ghr:ami_role,Value=validator' "$tmp_dir/calls" ||
  fail "validator launch must carry the fallback-cleanup role tag"
[[ "$(<"$tmp_dir/validator-id")" == "i-aaaaaaaaaaaaaaaaa" ]] ||
  fail "validator instance ID must be persisted for workflow cleanup"
[[ -f "$tmp_dir/launch-attempted" ]] ||
  fail "validator launch intent must be persisted before RunInstances"

run_validator tag-delayed
[[ "$(<"$tmp_dir/tag-reads")" == "2" ]] ||
  fail "successful validation must wait for the passed tag to become readable"

if run_validator preflight-passed; then
  fail "an already-passed AMI must fail exact candidate preflight"
fi
if grep -q '^tag:' "$tmp_dir/calls"; then
  fail "failed preflight must not alter validation tags"
fi
if grep -q '^terminate:' "$tmp_dir/calls"; then
  fail "failed preflight must not launch a validator"
fi
[[ ! -e "$tmp_dir/launch-attempted" ]] ||
  fail "failed preflight must not create a launch-attempt marker"

if run_validator preflight-wrong-release; then
  fail "an AMI from another release must fail exact provenance preflight"
fi
if grep -q '^tag:' "$tmp_dir/calls"; then
  fail "provenance failure must not alter validation tags"
fi

if run_validator registration-timeout -1 2; then
  fail "registration timeout must fail validation"
fi
grep -q 'Value=failed' "$tmp_dir/calls" || fail "registration timeout must tag the AMI failed"
if grep -q '^terminate:' "$tmp_dir/calls"; then
  fail "registration timeout must leave termination to workflow cleanup"
fi
if grep -q '^send-command$' "$tmp_dir/calls"; then
  fail "registration timeout must not send a validation command"
fi

if run_validator terminal-failure; then
  fail "terminal Run Command failure must fail validation"
fi
grep -q 'Value=failed' "$tmp_dir/calls" || fail "terminal failure must tag the AMI failed"
if grep -q '^terminate:' "$tmp_dir/calls"; then
  fail "terminal failure must leave termination to workflow cleanup"
fi

if run_validator passed-tag-unknown; then
  fail "an unknown passed-tag result must fail the build"
fi
grep -q 'Value=passed' "$tmp_dir/calls" ||
  fail "passed-tag unknown must still make exactly one passed mutation attempt"
if grep -q 'Value=failed' "$tmp_dir/calls"; then
  fail "passed-tag unknown must not send a conflicting failed mutation"
fi

if run_validator pending 2 -1; then
  fail "Run Command deadline must fail validation"
fi
grep -q 'Value=failed' "$tmp_dir/calls" || fail "deadline failure must tag the AMI failed"
if grep -q '^terminate:' "$tmp_dir/calls"; then
  fail "validation deadline must leave termination to workflow cleanup"
fi

started="$(date +%s)"
if run_validator run-hang 2 2; then
  fail "a hung validator launch must fail at the AWS request deadline"
fi
elapsed=$(($(date +%s) - started))
((elapsed < 4)) || fail "a hung validator launch must not outlive its AWS request deadline"

started="$(date +%s)"
if AMI_VALIDATION_TEST_REAL_SLEEP=true AMI_VALIDATION_POLL_SECONDS=2 \
  run_validator invocation-missing-deadline 2 1; then
  fail "InvocationDoesNotExist must not sleep past the validation deadline"
fi
elapsed=$(($(date +%s) - started))
((elapsed < 3)) || fail "InvocationDoesNotExist retry sleep must be deadline bounded"

echo "PASS: final AMI validator failure and cleanup behavior"
