#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/cleanup-release-validators.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$CLEANUP_SCRIPT" ]] || fail "$CLEANUP_SCRIPT must exist and be executable"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat >"$tmp_dir/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

service="${1:?}"
operation="${2:?}"
shift 2

case "$service:$operation" in
  ec2:describe-instances)
    count=0
    [[ ! -f "$CLEANUP_TEST_DESCRIBE_COUNT" ]] || count="$(<"$CLEANUP_TEST_DESCRIBE_COUNT")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$CLEANUP_TEST_DESCRIBE_COUNT"
    printf 'describe:%s\n' "$*" >>"$CLEANUP_TEST_CALLS"
    case "$CLEANUP_TEST_MODE" in
      known-lookup-failure)
        exit 255
        ;;
      known-duplicates)
        printf 'i-aaaaaaaaaaaaaaaaa\ti-aaaaaaaaaaaaaaaaa\ti-bbbbbbbbbbbbbbbbb\n'
        ;;
      unknown-delayed)
        if ((count == 1)); then
          printf 'None\n'
        else
          printf 'i-ccccccccccccccccc\n'
        fi
        ;;
      *)
        printf 'None\n'
        ;;
    esac
    ;;
  ec2:terminate-instances)
    printf 'terminate:%s\n' "$*" >>"$CLEANUP_TEST_CALLS"
    [[ "$CLEANUP_TEST_MODE" != "known-terminate-failure" ]] || exit 255
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
exec /bin/sleep "$@"
EOF
chmod +x "$tmp_dir/sleep"

run_cleanup() {
  local mode="$1"
  : >"$tmp_dir/calls"
  rm -f "$tmp_dir/describe-count"

  PATH="$tmp_dir:$PATH" \
    ARCHITECTURE=amd64 \
    AWS_REGION=us-east-1 \
    RELEASE_ID=123.1 \
    VALIDATOR_INSTANCE_ID_FILE="$tmp_dir/validator-id" \
    VALIDATOR_LAUNCH_MARKER_FILE="$tmp_dir/launch-attempted" \
    AMI_VALIDATOR_CLEANUP_DEADLINE_MILLISECONDS=120 \
    AMI_VALIDATOR_CLEANUP_POLL_MILLISECONDS=10 \
    AMI_VALIDATOR_CLEANUP_AWS_CLI_TIMEOUT_SECONDS=1 \
    CLEANUP_TEST_MODE="$mode" \
    CLEANUP_TEST_CALLS="$tmp_dir/calls" \
    CLEANUP_TEST_DESCRIBE_COUNT="$tmp_dir/describe-count" \
    "$CLEANUP_SCRIPT"
}

rm -f "$tmp_dir/validator-id" "$tmp_dir/launch-attempted"
run_cleanup prelaunch
[[ "$(<"$tmp_dir/describe-count")" == "1" ]] ||
  fail "PRELAUNCH cleanup must perform one complete fallback lookup"
if grep -q '^terminate:' "$tmp_dir/calls"; then
  fail "PRELAUNCH with no matching validator must not terminate"
fi

printf 'attempted\n' >"$tmp_dir/launch-attempted"
printf 'i-aaaaaaaaaaaaaaaaa\n' >"$tmp_dir/validator-id"
run_cleanup known-duplicates
[[ "$(<"$tmp_dir/describe-count")" == "1" ]] ||
  fail "KNOWN cleanup must perform exactly one fallback lookup"
[[ "$(grep -c '^terminate:' "$tmp_dir/calls")" == "2" ]] ||
  fail "KNOWN cleanup must terminate each unique instance exactly once"
[[ "$(grep -c '^terminate:.*i-aaaaaaaaaaaaaaaaa' "$tmp_dir/calls")" == "1" ]] ||
  fail "the persisted validator must be terminated exactly once"

printf 'attempted\n' >"$tmp_dir/launch-attempted"
printf 'i-aaaaaaaaaaaaaaaaa\n' >"$tmp_dir/validator-id"
if run_cleanup known-lookup-failure; then
  fail "KNOWN cleanup must fail when its complete fallback lookup fails"
fi
if grep -q '^terminate:' "$tmp_dir/calls"; then
  fail "KNOWN cleanup must not terminate from a partial lookup set"
fi

printf 'attempted\n' >"$tmp_dir/launch-attempted"
printf 'i-aaaaaaaaaaaaaaaaa\n' >"$tmp_dir/validator-id"
if run_cleanup known-terminate-failure; then
  fail "KNOWN cleanup must fail when termination fails"
fi
[[ "$(grep -c '^terminate:' "$tmp_dir/calls")" == "1" ]] ||
  fail "an ambiguous terminate mutation must not be retried"

printf 'attempted\n' >"$tmp_dir/launch-attempted"
rm -f "$tmp_dir/validator-id"
run_cleanup unknown-delayed
(( $(<"$tmp_dir/describe-count") >= 2 )) ||
  fail "LAUNCH_UNKNOWN cleanup must repeat complete scans after an empty result"
[[ "$(grep -c '^terminate:' "$tmp_dir/calls")" == "1" ]] ||
  fail "LAUNCH_UNKNOWN cleanup must terminate a delayed instance at most once"

printf 'attempted\n' >"$tmp_dir/launch-attempted"
rm -f "$tmp_dir/validator-id"
if run_cleanup unknown-empty; then
  fail "LAUNCH_UNKNOWN cleanup must not claim success when no instance becomes visible"
fi
(( $(<"$tmp_dir/describe-count") >= 2 )) ||
  fail "LAUNCH_UNKNOWN cleanup must scan for its entire bounded phase"
if grep -q '^terminate:' "$tmp_dir/calls"; then
  fail "an empty LAUNCH_UNKNOWN cleanup must not terminate"
fi

echo "PASS: validator fallback cleanup state machine"
