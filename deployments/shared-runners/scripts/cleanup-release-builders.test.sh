#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/cleanup-release-builders.sh"

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
printf '%s:%s attempts=%s args=%s\n' \
  "$service" "$operation" "${AWS_MAX_ATTEMPTS:-default}" "$*" >>"$CLEANUP_TEST_CALLS"

case "$service:$operation" in
  ec2:describe-instances)
    [[ "$CLEANUP_TEST_MODE" != "lookup-failure" ]] || exit 255
    case "$CLEANUP_TEST_MODE" in
      duplicates | terminate-failure)
        printf 'i-aaaaaaaaaaaaaaaaa\ti-aaaaaaaaaaaaaaaaa\ti-bbbbbbbbbbbbbbbbb\n'
        ;;
      malformed)
        printf 'not-an-instance\n'
        ;;
      *)
        printf 'None\n'
        ;;
    esac
    ;;
  ec2:terminate-instances)
    if [[ "$CLEANUP_TEST_MODE" == "terminate-failure" && "$*" == *i-aaaaaaaaaaaaaaaaa* ]]; then
      exit 255
    fi
    ;;
  *)
    echo "unexpected aws call: $service $operation $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$tmp_dir/aws"

run_cleanup() {
  local mode="$1"
  : >"$tmp_dir/calls"

  PATH="$tmp_dir:$PATH" \
    ARCHITECTURE=amd64 \
    AWS_REGION=us-east-1 \
    RELEASE_ID=123.1 \
    AMI_BUILDER_CLEANUP_DEADLINE_MILLISECONDS=1000 \
    AMI_BUILDER_CLEANUP_AWS_CLI_TIMEOUT_SECONDS=1 \
    CLEANUP_TEST_MODE="$mode" \
    CLEANUP_TEST_CALLS="$tmp_dir/calls" \
    "$CLEANUP_SCRIPT"
}

run_cleanup empty
[[ "$(grep -c '^ec2:describe-instances ' "$tmp_dir/calls")" == "1" ]] ||
  fail "builder cleanup must perform one complete lookup"
if grep -q '^ec2:terminate-instances ' "$tmp_dir/calls"; then
  fail "an empty builder lookup must not terminate"
fi

run_cleanup duplicates
[[ "$(grep -c '^ec2:terminate-instances ' "$tmp_dir/calls")" == "2" ]] ||
  fail "builder cleanup must terminate each unique instance exactly once"
grep -q '^ec2:describe-instances .*--page-size 100' "$tmp_dir/calls" ||
  fail "builder cleanup must use explicit AWS CLI pagination"
grep -q 'Name=tag:ghr:ami_role,Values=builder' "$tmp_dir/calls" ||
  fail "builder cleanup must use the exact builder role tag"
if grep '^ec2:terminate-instances ' "$tmp_dir/calls" | grep -qv 'attempts=1 '; then
  fail "builder termination must disable AWS retries"
fi

if run_cleanup lookup-failure; then
  fail "builder cleanup must fail when its complete lookup fails"
fi
if grep -q '^ec2:terminate-instances ' "$tmp_dir/calls"; then
  fail "builder cleanup must not terminate after a failed lookup"
fi

if run_cleanup malformed; then
  fail "builder cleanup must reject malformed instance IDs"
fi
if grep -q '^ec2:terminate-instances ' "$tmp_dir/calls"; then
  fail "builder cleanup must validate every ID before terminating"
fi

if run_cleanup terminate-failure; then
  fail "builder cleanup must fail when any termination fails"
fi
[[ "$(grep -c '^ec2:terminate-instances ' "$tmp_dir/calls")" == "2" ]] ||
  fail "builder cleanup must attempt every unique instance after one termination fails"
[[ "$(grep -c '^ec2:terminate-instances .*i-aaaaaaaaaaaaaaaaa' "$tmp_dir/calls")" == "1" ]] ||
  fail "an ambiguous builder termination must not be retried"

echo "PASS: builder fallback cleanup"
