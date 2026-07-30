#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/is-ami-validation.sh"
WRAPPER="$SCRIPT_DIR/start-runner.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$HELPER" ]] || fail "$HELPER must exist and be executable"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url="${*: -1}"
output_file=""
while (($#)); do
  case "$1" in
    --output)
      output_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

case "$url" in
  */latest/api/token)
    [[ "${IMDS_TOKEN_AVAILABLE:-true}" == "true" ]] || exit 7
    printf 'test-token' >"$output_file"
    printf '200'
    ;;
  */latest/meta-data/tags/instance/ghr:ami_validation)
    if [[ "${VALIDATION_TAG_PRESENT:-true}" == "true" ]]; then
      printf '%s' "${VALIDATION_TAG_VALUE:-true}" >"$output_file"
      printf '200'
    else
      : >"$output_file"
      printf '404'
    fi
    ;;
  *)
    echo "unexpected URL: $url" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$tmp_dir/curl"

if ! PATH="$tmp_dir:$PATH" VALIDATION_TAG_VALUE=true "$HELPER"; then
  fail "true validation tag must be detected"
fi

set +e
PATH="$tmp_dir:$PATH" VALIDATION_TAG_VALUE=false "$HELPER"
status=$?
set -e
[[ "$status" == "1" ]] || fail "false validation tag must return the explicit non-validation status"

set +e
PATH="$tmp_dir:$PATH" VALIDATION_TAG_PRESENT=false "$HELPER"
status=$?
set -e
[[ "$status" == "1" ]] || fail "missing validation tag must return the explicit non-validation status"

set +e
PATH="$tmp_dir:$PATH" IMDS_TOKEN_AVAILABLE=false "$HELPER"
status=$?
set -e
[[ "$status" == "2" ]] || fail "unavailable IMDS must return a fail-closed error status"

guard_line="$(grep -n 'is-ami-validation.sh' "$WRAPPER" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016 # The Packer template placeholder is intentionally literal.
runner_line="$(grep -nFx '${start_runner}' "$WRAPPER" | cut -d: -f1)"

[[ -n "$guard_line" ]] || fail "start-runner wrapper must invoke the validation helper"
[[ -n "$runner_line" ]] || fail "start-runner wrapper placeholder is missing"
(( guard_line < runner_line )) || fail "validation guard must execute before the normal runner template"
grep -q 'Unable to determine AMI validation mode; refusing runner registration' "$WRAPPER" ||
  fail "start-runner must fail closed when validation mode cannot be read"
# shellcheck disable=SC2016 # Match the literal shell variable reference in the wrapper.
grep -q 'exit "\$validation_mode_status"' "$WRAPPER" ||
  fail "start-runner must stop before registration after an IMDS failure"

echo "PASS: AMI validation mode guard"
