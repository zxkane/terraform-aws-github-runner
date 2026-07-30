#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANNEL_SCRIPT="$SCRIPT_DIR/ami-channel.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$CHANNEL_SCRIPT" ]] || fail "$CHANNEL_SCRIPT must exist and be executable"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source "$AMI_TEST_STATE"

save_state() {
  printf 'active=%q\nprevious=%q\nrecovery=%q\ncandidate=%q\nunreadable_active=%q\nunreadable_previous=%q\nunreadable_recovery=%q\n' \
    "$active" \
    "$previous" \
    "$recovery" \
    "$candidate" \
    "${unreadable_active:-false}" \
    "${unreadable_previous:-false}" \
    "${unreadable_recovery:-false}" > "$AMI_TEST_STATE"
}

service="${1:?}"
operation="${2:?}"
shift 2

case "$service:$operation" in
  ec2:describe-images)
    if [[ " $* " == *" --image-ids "* ]]; then
      image_id=""
      while (($#)); do
        if [[ "$1" == "--image-ids" ]]; then
          image_id="$2"
          break
        fi
        shift
      done
      [[ "$image_id" == "$active" || "$image_id" == "$previous" || "$image_id" == "${candidate:-}" ]] || {
        printf '{"Images":[]}\n'
        exit 0
      }
      arch="${ARCHITECTURE:-amd64}"
      creation_date="${CANDIDATE_CREATION_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
      printf '{"Images":[{"ImageId":"%s","Architecture":"%s","State":"available","CreationDate":"%s","Tags":[]}]}\n' \
        "$image_id" \
        "$([[ "$arch" == "amd64" ]] && printf x86_64 || printf arm64)" \
        "$creation_date"
    else
      case "${CANDIDATE_COUNT:-1}" in
        0) printf '{"Images":[]}\n' ;;
        1)
          creation_date="${CANDIDATE_CREATION_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
          printf '{"Images":[{"ImageId":"%s","Architecture":"%s","State":"available","CreationDate":"%s","Tags":[{"Key":"ghr:source_revision","Value":"%s"}]}]}\n' \
            "$candidate" \
            "$([[ "${ARCHITECTURE:-amd64}" == "amd64" ]] && printf x86_64 || printf arm64)" \
            "$creation_date" \
            "${SOURCE_REVISION:-0000000000000000000000000000000000000000}"
          ;;
        *) printf '{"Images":[{"ImageId":"%s"},{"ImageId":"ami-eeeeeeeeeeeeeeeee"}]}\n' "$candidate" ;;
      esac
    fi
    ;;
  ssm:get-parameter)
    printf 'get=%s\n' "${AWS_MAX_ATTEMPTS:-unset}" >>"$AMI_TEST_ATTEMPTS"
    [[ "${HANG_PARAMETER_READ:-false}" != "true" ]] || sleep 5
    name=""
    while (($#)); do
      if [[ "$1" == "--name" ]]; then
        name="$2"
        break
      fi
      shift
    done
    case "$name" in
      *ami_previous_id)
        [[ "${unreadable_previous:-false}" != "true" ]] || exit 255
        printf '%s\n' "$previous"
        ;;
      *ami_recovery_id)
        [[ "${unreadable_recovery:-false}" != "true" ]] || exit 255
        printf '%s\n' "$recovery"
        ;;
      *)
        if [[ "${DRIFT_RECOVERY_BEFORE_PREVIOUS:-false}" == "true" &&
          -f "$AMI_TEST_RECOVERY_ESTABLISHED" &&
          ! -f "$AMI_TEST_RECOVERY_DRIFTED" ]]; then
          recovery="ami-ddddddddddddddddd"
          save_state
          touch "$AMI_TEST_RECOVERY_DRIFTED"
        fi
        [[ "${unreadable_active:-false}" != "true" ]] || exit 255
        printf '%s\n' "$active"
        ;;
    esac
    ;;
  ssm:put-parameter)
    printf 'put=%s\n' "${AWS_MAX_ATTEMPTS:-unset}" >>"$AMI_TEST_ATTEMPTS"
    name=""
    value=""
    while (($#)); do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        --value) value="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$name" in
      *ami_previous_id) channel=previous ;;
      *ami_recovery_id) channel=recovery ;;
      *) channel=active ;;
    esac
    printf '%s=%s\n' "$channel" "$value" >> "$AMI_TEST_CALLS"
    if [[ "$channel" == "recovery" ]]; then
      [[ "${FAIL_RECOVERY_WRITE:-false}" != "true" ]] || exit 255
      recovery="$value"
      save_state
      touch "$AMI_TEST_RECOVERY_ESTABLISHED"
    elif [[ "$channel" == "previous" ]]; then
      [[ "${FAIL_PREVIOUS_WRITE:-false}" != "true" ]] || exit 255
      if [[ "${FAIL_PREVIOUS_RESTORE:-false}" == "true" && "$value" == "ami-bbbbbbbbbbbbbbbbb" ]]; then
        exit 255
      fi
      previous="$value"
      if [[ -n "${DRIFT_ACTIVE_AFTER_PREVIOUS:-}" ]]; then
        active="$DRIFT_ACTIVE_AFTER_PREVIOUS"
      elif [[ "${ACTIVE_C_AFTER_PREVIOUS:-false}" == "true" ]]; then
        active="$candidate"
      fi
      if [[ "${UNREADABLE_PREVIOUS_AFTER_WRITE:-false}" == "true" ]]; then
        unreadable_previous=true
      fi
      if [[ "${DRIFT_RECOVERY_AFTER_PREVIOUS:-false}" == "true" ]]; then
        recovery="ami-ddddddddddddddddd"
      fi
      save_state
      [[ "${TIMEOUT_PREVIOUS_AFTER_APPLY:-false}" != "true" ]] || exit 255
    else
      if [[ "${FAIL_ACTIVE_WRITE_ONCE:-false}" == "true" && ! -f "$AMI_TEST_ACTIVE_FAILED" ]]; then
        touch "$AMI_TEST_ACTIVE_FAILED"
        exit 255
      fi
      if [[ "${FAIL_ACTIVE_RESTORE:-false}" == "true" && "$value" == "ami-aaaaaaaaaaaaaaaaa" ]]; then
        exit 255
      fi
      active="$value"
      if [[ "${DRIFT_RECOVERY_AFTER_ACTIVE:-false}" == "true" && "$value" == "$candidate" ]]; then
        recovery="ami-ddddddddddddddddd"
      fi
      if [[ "${UNREADABLE_ACTIVE_AFTER_WRITE:-false}" == "true" ]]; then
        unreadable_active=true
      fi
      save_state
      [[ "${TIMEOUT_ACTIVE_AFTER_APPLY:-false}" != "true" ]] || exit 255
    fi
    ;;
  ec2:describe-launch-template-versions)
    if [[ "${FAIL_LT_RESOLVE:-false}" == "true" ]]; then
      if [[ -n "${DRIFT_ACTIVE_ON_LT_FAILURE:-}" ]]; then
        active="$DRIFT_ACTIVE_ON_LT_FAILURE"
      fi
      if [[ -n "${DRIFT_PREVIOUS_ON_LT_FAILURE:-}" ]]; then
        previous="$DRIFT_PREVIOUS_ON_LT_FAILURE"
      fi
      if [[ -n "${DRIFT_RECOVERY_ON_LT_FAILURE:-}" ]]; then
        recovery="$DRIFT_RECOVERY_ON_LT_FAILURE"
      fi
      save_state
      exit 255
    fi
    printf '%s\n' "$active"
    ;;
  *)
    echo "unexpected aws call: $service $operation $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$tmp_dir/aws"

source_revision="1111111111111111111111111111111111111111"

reset_state() {
  printf 'active=%q\nprevious=%q\nrecovery=%q\ncandidate=%q\nunreadable_active=false\nunreadable_previous=false\nunreadable_recovery=false\n' \
    "ami-aaaaaaaaaaaaaaaaa" \
    "ami-bbbbbbbbbbbbbbbbb" \
    "ami-bbbbbbbbbbbbbbbbb" \
    "ami-ccccccccccccccccc" > "$tmp_dir/state"
  : > "$tmp_dir/calls"
  : > "$tmp_dir/attempts"
  rm -f "$tmp_dir/active-failed"
  rm -f "$tmp_dir/recovery-established" "$tmp_dir/recovery-drifted"
}

run_channel() {
  PATH="$tmp_dir:$PATH" \
    AWS_REGION=us-east-1 \
    ARCHITECTURE=amd64 \
    SOURCE_REVISION="$source_revision" \
    AMI_TEST_STATE="$tmp_dir/state" \
    AMI_TEST_CALLS="$tmp_dir/calls" \
    AMI_TEST_ATTEMPTS="$tmp_dir/attempts" \
    AMI_TEST_ACTIVE_FAILED="$tmp_dir/active-failed" \
    AMI_TEST_RECOVERY_ESTABLISHED="$tmp_dir/recovery-established" \
    AMI_TEST_RECOVERY_DRIFTED="$tmp_dir/recovery-drifted" \
    AMI_CHANNEL_DEADLINE_SECONDS=1 \
    AMI_CHANNEL_POLL_SECONDS=0.05 \
    "$CHANNEL_SCRIPT" "$@"
}

assert_state() {
  local active=""
  local previous=""
  local recovery=""
  # shellcheck source=/dev/null
  source "$tmp_dir/state"
  [[ "$active" == "$1" ]] || fail "active=$active, expected $1"
  [[ "$previous" == "$2" ]] || fail "previous=$previous, expected $2"
  if (($# >= 3)); then
    [[ "$recovery" == "$3" ]] || fail "recovery=$recovery, expected $3"
  fi
}

reset_state
sed -i 's/recovery=ami-bbbbbbbbbbbbbbbbb/recovery=ami-ddddddddddddddddd/' "$tmp_dir/state"
run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"
assert_state "ami-ccccccccccccccccc" "ami-aaaaaaaaaaaaaaaaa" "ami-bbbbbbbbbbbbbbbbb"
[[ "$(cat "$tmp_dir/calls")" == $'recovery=ami-bbbbbbbbbbbbbbbbb\nprevious=ami-aaaaaaaaaaaaaaaaa\nactive=ami-ccccccccccccccccc' ]] ||
  fail "promotion must protect the displaced previous image before channel writes"
if grep '^put=' "$tmp_dir/attempts" | grep -qv '^put=1$'; then
  fail "every SSM mutation must disable AWS CLI retries"
fi
if grep '^get=' "$tmp_dir/attempts" | grep -qv '^get=unset$'; then
  fail "SSM reads must retain the AWS CLI retry policy"
fi

reset_state
sed -i 's/recovery=ami-bbbbbbbbbbbbbbbbb/recovery=ami-ddddddddddddddddd/' "$tmp_dir/state"
if FAIL_RECOVERY_WRITE=true \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "promotion must fail before channel writes when recovery protection cannot be established"
fi
assert_state "ami-aaaaaaaaaaaaaaaaa" "ami-bbbbbbbbbbbbbbbbb" "ami-ddddddddddddddddd"
[[ "$(cat "$tmp_dir/calls")" == "recovery=ami-bbbbbbbbbbbbbbbbb" ]] ||
  fail "a failed recovery write must prevent active and previous mutations"

reset_state
TIMEOUT_PREVIOUS_AFTER_APPLY=true TIMEOUT_ACTIVE_AFTER_APPLY=true \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"
assert_state "ami-ccccccccccccccccc" "ami-aaaaaaaaaaaaaaaaa"
[[ "$(cat "$tmp_dir/calls")" == $'previous=ami-aaaaaaaaaaaaaaaaa\nactive=ami-ccccccccccccccccc' ]] ||
  fail "applied writes with timeout responses must not be repeated"

reset_state
sed -i 's/previous=ami-bbbbbbbbbbbbbbbbb/previous=ami-aaaaaaaaaaaaaaaaa/' "$tmp_dir/state"
sed -i 's/recovery=ami-bbbbbbbbbbbbbbbbb/recovery=ami-aaaaaaaaaaaaaaaaa/' "$tmp_dir/state"
run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"
assert_state "ami-ccccccccccccccccc" "ami-aaaaaaaaaaaaaaaaa" "ami-aaaaaaaaaaaaaaaaa"
[[ "$(cat "$tmp_dir/calls")" == "active=ami-ccccccccccccccccc" ]] ||
  fail "promotion must skip redundant recovery and previous mutations"

reset_state
sed -i 's/active=ami-aaaaaaaaaaaaaaaaa/active=ami-ccccccccccccccccc/' "$tmp_dir/state"
run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"
assert_state "ami-ccccccccccccccccc" "ami-bbbbbbbbbbbbbbbbb"
[[ ! -s "$tmp_dir/calls" ]] || fail "re-promoting active candidate must not write channels"

reset_state
if CANDIDATE_COUNT=2 run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "multiple candidate images must fail"
fi
assert_state "ami-aaaaaaaaaaaaaaaaa" "ami-bbbbbbbbbbbbbbbbb"
[[ ! -s "$tmp_dir/calls" ]] || fail "invalid candidate selection must not write channels"

reset_state
if FAIL_PREVIOUS_WRITE=true run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "an unchanged failed previous write must fail promotion"
fi
assert_state "ami-aaaaaaaaaaaaaaaaa" "ami-bbbbbbbbbbbbbbbbb"

reset_state
old_creation_date="$(date -u -d '8 days ago' +%Y-%m-%dT%H:%M:%SZ)"
if CANDIDATE_CREATION_DATE="$old_creation_date" \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "a candidate at least seven days old must fail promotion"
fi
assert_state "ami-aaaaaaaaaaaaaaaaa" "ami-bbbbbbbbbbbbbbbbb"
[[ ! -s "$tmp_dir/calls" ]] || fail "an aged candidate must not write channels"

reset_state
frozen_epoch="$(date -u +%s)"
boundary_creation_date="$(date -u -d "@$((frozen_epoch - 7 * 24 * 60 * 60))" +%Y-%m-%dT%H:%M:%SZ)"
if AMI_CHANNEL_EVALUATION_EPOCH="$frozen_epoch" CANDIDATE_CREATION_DATE="$boundary_creation_date" \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "a candidate exactly 168 hours old at the frozen evaluation time must fail"
fi
[[ ! -s "$tmp_dir/calls" ]] || fail "the exact age boundary must fail before channel writes"

reset_state
sed -i 's/recovery=ami-bbbbbbbbbbbbbbbbb/recovery=ami-ddddddddddddddddd/' "$tmp_dir/state"
if DRIFT_RECOVERY_BEFORE_PREVIOUS=true \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "recovery drift during the pre-destructive full-tuple read must fail"
fi
assert_state "ami-aaaaaaaaaaaaaaaaa" "ami-bbbbbbbbbbbbbbbbb" "ami-ddddddddddddddddd"
[[ "$(cat "$tmp_dir/calls")" == "recovery=ami-bbbbbbbbbbbbbbbbb" ]] ||
  fail "pre-destructive recovery drift must prevent previous and active writes"

reset_state
if DRIFT_RECOVERY_AFTER_PREVIOUS=true \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "recovery drift after the previous write must fail promotion"
fi
assert_state "ami-aaaaaaaaaaaaaaaaa" "ami-aaaaaaaaaaaaaaaaa" "ami-ddddddddddddddddd"
[[ "$(cat "$tmp_dir/calls")" == "previous=ami-aaaaaaaaaaaaaaaaa" ]] ||
  fail "recovery drift after previous must prevent active and compensation writes"

reset_state
if DRIFT_RECOVERY_AFTER_ACTIVE=true \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "final convergence must reject a (C,A,X) tuple"
fi
assert_state "ami-ccccccccccccccccc" "ami-aaaaaaaaaaaaaaaaa" "ami-ddddddddddddddddd"
[[ "$(cat "$tmp_dir/calls")" == $'previous=ami-aaaaaaaaaaaaaaaaa\nactive=ami-ccccccccccccccccc' ]] ||
  fail "final recovery drift must not authorize compensation writes"

reset_state
if FAIL_ACTIVE_WRITE_ONCE=true run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "active write failure must fail promotion after compensation"
fi
assert_state "ami-aaaaaaaaaaaaaaaaa" "ami-bbbbbbbbbbbbbbbbb"

reset_state
if UNREADABLE_ACTIVE_AFTER_WRITE=true \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "an unreadable active channel after its write must fail without compensation"
fi
assert_state "ami-ccccccccccccccccc" "ami-aaaaaaaaaaaaaaaaa"
[[ "$(cat "$tmp_dir/calls")" == $'previous=ami-aaaaaaaaaaaaaaaaa\nactive=ami-ccccccccccccccccc' ]] ||
  fail "an unreadable active write result must not trigger a compensation write"

reset_state
ACTIVE_C_AFTER_PREVIOUS=true \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"
assert_state "ami-ccccccccccccccccc" "ami-aaaaaaaaaaaaaaaaa"
[[ "$(cat "$tmp_dir/calls")" == "previous=ami-aaaaaaaaaaaaaaaaa" ]] ||
  fail "an observed (C,A) tuple must skip the active write"

reset_state
if DRIFT_ACTIVE_AFTER_PREVIOUS=ami-ddddddddddddddddd \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "external active drift must fail promotion"
fi
assert_state "ami-ddddddddddddddddd" "ami-aaaaaaaaaaaaaaaaa"
[[ "$(cat "$tmp_dir/calls")" == "previous=ami-aaaaaaaaaaaaaaaaa" ]] ||
  fail "external drift must prevent compensation writes"

reset_state
if UNREADABLE_PREVIOUS_AFTER_WRITE=true \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "an unreadable channel must fail promotion"
fi
assert_state "ami-aaaaaaaaaaaaaaaaa" "ami-aaaaaaaaaaaaaaaaa"
[[ "$(cat "$tmp_dir/calls")" == "previous=ami-aaaaaaaaaaaaaaaaa" ]] ||
  fail "an unreadable tuple must prevent compensation writes"

reset_state
if FAIL_LT_RESOLVE=true \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "launch template verification failure must fail after compensation"
fi
assert_state "ami-aaaaaaaaaaaaaaaaa" "ami-bbbbbbbbbbbbbbbbb"
[[ "$(cat "$tmp_dir/calls")" == $'previous=ami-aaaaaaaaaaaaaaaaa\nactive=ami-ccccccccccccccccc\nactive=ami-aaaaaaaaaaaaaaaaa\nprevious=ami-bbbbbbbbbbbbbbbbb' ]] ||
  fail "promotion compensation must restore active before previous"

reset_state
if FAIL_LT_RESOLVE=true FAIL_PREVIOUS_RESTORE=true \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "a failed previous-channel compensation must fail promotion"
fi
assert_state "ami-aaaaaaaaaaaaaaaaa" "ami-aaaaaaaaaaaaaaaaa"
[[ "$(cat "$tmp_dir/calls")" == $'previous=ami-aaaaaaaaaaaaaaaaa\nactive=ami-ccccccccccccccccc\nactive=ami-aaaaaaaaaaaaaaaaa\nprevious=ami-bbbbbbbbbbbbbbbbb' ]] ||
  fail "failed previous compensation must stop after its single write attempt"

reset_state
if FAIL_LT_RESOLVE=true DRIFT_PREVIOUS_ON_LT_FAILURE=ami-ddddddddddddddddd \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "drift before compensation must fail promotion"
fi
assert_state "ami-ccccccccccccccccc" "ami-ddddddddddddddddd"
[[ "$(cat "$tmp_dir/calls")" == $'previous=ami-aaaaaaaaaaaaaaaaa\nactive=ami-ccccccccccccccccc' ]] ||
  fail "compensation must not overwrite an unexpected tuple"

reset_state
if FAIL_LT_RESOLVE=true DRIFT_RECOVERY_ON_LT_FAILURE=ami-ddddddddddddddddd \
  run_channel promote --build-run-id 123 --build-run-attempt 2 --source-revision "$source_revision"; then
  fail "recovery drift before promotion compensation must fail"
fi
assert_state "ami-ccccccccccccccccc" "ami-aaaaaaaaaaaaaaaaa" "ami-ddddddddddddddddd"
[[ "$(cat "$tmp_dir/calls")" == $'previous=ami-aaaaaaaaaaaaaaaaa\nactive=ami-ccccccccccccccccc' ]] ||
  fail "promotion compensation must not write after recovery drift"

reset_state
run_channel rollback
assert_state "ami-bbbbbbbbbbbbbbbbb" "ami-bbbbbbbbbbbbbbbbb" "ami-aaaaaaaaaaaaaaaaa"
[[ "$(cat "$tmp_dir/calls")" == $'recovery=ami-aaaaaaaaaaaaaaaaa\nactive=ami-bbbbbbbbbbbbbbbbb' ]] ||
  fail "rollback must protect the displaced active image before writing active"

reset_state
sed -i 's/recovery=ami-bbbbbbbbbbbbbbbbb/recovery=ami-aaaaaaaaaaaaaaaaa/' "$tmp_dir/state"
run_channel rollback
assert_state "ami-bbbbbbbbbbbbbbbbb" "ami-bbbbbbbbbbbbbbbbb" "ami-aaaaaaaaaaaaaaaaa"
[[ "$(cat "$tmp_dir/calls")" == "active=ami-bbbbbbbbbbbbbbbbb" ]] ||
  fail "rollback must skip an already-established recovery mutation"

reset_state
sed -i 's/active=ami-aaaaaaaaaaaaaaaaa/active=ami-bbbbbbbbbbbbbbbbb/' "$tmp_dir/state"
run_channel rollback
assert_state "ami-bbbbbbbbbbbbbbbbb" "ami-bbbbbbbbbbbbbbbbb"
[[ ! -s "$tmp_dir/calls" ]] || fail "idempotent rollback must not write"

reset_state
if FAIL_ACTIVE_WRITE_ONCE=true run_channel rollback; then
  fail "an unapplied rollback write must fail"
fi
assert_state "ami-aaaaaaaaaaaaaaaaa" "ami-bbbbbbbbbbbbbbbbb"
[[ "$(cat "$tmp_dir/calls")" == $'recovery=ami-aaaaaaaaaaaaaaaaa\nactive=ami-bbbbbbbbbbbbbbbbb' ]] ||
  fail "an unapplied rollback must not issue a compensation write"

reset_state
started="$(date +%s)"
if HANG_PARAMETER_READ=true run_channel rollback; then
  fail "a hung channel read must fail"
fi
elapsed=$(($(date +%s) - started))
((elapsed < 4)) || fail "a hung AWS CLI call must not outlive the channel deadline"
[[ ! -s "$tmp_dir/calls" ]] || fail "an unreadable initial tuple must not write"

reset_state
if FAIL_LT_RESOLVE=true run_channel rollback; then
  fail "rollback LT verification failure must fail after restoring active"
fi
assert_state "ami-aaaaaaaaaaaaaaaaa" "ami-bbbbbbbbbbbbbbbbb"
[[ "$(cat "$tmp_dir/calls")" == $'recovery=ami-aaaaaaaaaaaaaaaaa\nactive=ami-bbbbbbbbbbbbbbbbb\nactive=ami-aaaaaaaaaaaaaaaaa' ]] ||
  fail "rollback compensation must write only active"

reset_state
if FAIL_LT_RESOLVE=true FAIL_ACTIVE_RESTORE=true run_channel rollback; then
  fail "a failed rollback compensation write must fail"
fi
assert_state "ami-bbbbbbbbbbbbbbbbb" "ami-bbbbbbbbbbbbbbbbb"
[[ "$(cat "$tmp_dir/calls")" == $'recovery=ami-aaaaaaaaaaaaaaaaa\nactive=ami-bbbbbbbbbbbbbbbbb\nactive=ami-aaaaaaaaaaaaaaaaa' ]] ||
  fail "failed rollback compensation must not issue another write"

reset_state
if FAIL_LT_RESOLVE=true DRIFT_ACTIVE_ON_LT_FAILURE=ami-ddddddddddddddddd run_channel rollback; then
  fail "rollback external drift must fail"
fi
assert_state "ami-ddddddddddddddddd" "ami-bbbbbbbbbbbbbbbbb"
[[ "$(cat "$tmp_dir/calls")" == $'recovery=ami-aaaaaaaaaaaaaaaaa\nactive=ami-bbbbbbbbbbbbbbbbb' ]] ||
  fail "rollback must not overwrite external drift"

reset_state
if FAIL_LT_RESOLVE=true DRIFT_RECOVERY_ON_LT_FAILURE=ami-ddddddddddddddddd run_channel rollback; then
  fail "recovery drift before rollback compensation must fail"
fi
assert_state "ami-bbbbbbbbbbbbbbbbb" "ami-bbbbbbbbbbbbbbbbb" "ami-ddddddddddddddddd"
[[ "$(cat "$tmp_dir/calls")" == $'recovery=ami-aaaaaaaaaaaaaaaaa\nactive=ami-bbbbbbbbbbbbbbbbb' ]] ||
  fail "rollback compensation must not write after recovery drift"

echo "PASS: AMI channel promotion and rollback"
