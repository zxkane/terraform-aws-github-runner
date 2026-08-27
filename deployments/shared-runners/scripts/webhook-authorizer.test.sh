#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTHORIZER_SCRIPT="$SCRIPT_DIR/webhook-authorizer.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$AUTHORIZER_SCRIPT" ]] || fail "$AUTHORIZER_SCRIPT must exist and be executable"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat >"$tmp_dir/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

service="${1:?}"
operation="${2:?}"
shift 2
printf '%s:%s args=%s\n' "$service" "$operation" "$*" >>"$AUTHORIZER_TEST_CALLS"

authorization_state_file="$AUTHORIZER_TEST_STATE"

case "$service:$operation" in
  apigatewayv2:get-routes)
    if [[ "$AUTHORIZER_TEST_MODE" == "missing-route" ]]; then
      printf 'None\n'
    else
      printf 'route-abc\n'
    fi
    ;;
  apigatewayv2:get-route)
    cat "$authorization_state_file"
    ;;
  apigatewayv2:update-route)
    if [[ "$*" == *"--authorization-type NONE"* ]]; then
      printf 'NONE\tNone\n' >"$authorization_state_file"
    elif [[ "$AUTHORIZER_TEST_MODE" == "wrong-authorizer" ]]; then
      printf 'CUSTOM\tsome-other-authorizer\n' >"$authorization_state_file"
    else
      printf 'CUSTOM\tauth-xyz\n' >"$authorization_state_file"
    fi
    printf '{}\n'
    ;;
  *)
    echo "unexpected aws call: $service $operation $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$tmp_dir/aws"

cat >"$tmp_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'curl args=%s\n' "$*" >>"$AUTHORIZER_TEST_CALLS"

case "$AUTHORIZER_TEST_MODE" in
  denying) printf '403' ;;
  unreachable) exit 7 ;;
  unexpected-status) printf '201' ;;
  *) printf '401' ;;
esac
EOF
chmod +x "$tmp_dir/curl"

run_authorizer() {
  local mode="$1"
  shift
  PATH="$tmp_dir:$PATH" \
    AUTHORIZER_TEST_MODE="$mode" \
    AUTHORIZER_TEST_CALLS="$tmp_dir/calls" \
    AUTHORIZER_TEST_STATE="$tmp_dir/state" \
    "$AUTHORIZER_SCRIPT" "$@"
}

reset_state() {
  : >"$tmp_dir/calls"
  printf 'NONE\tNone\n' >"$tmp_dir/state"
}

attach_args=(
  attach
  --api-id api-123
  --authorizer-id auth-xyz
  --region us-east-1
  --route-key 'POST /webhook'
  --endpoint https://api.example.com/webhook
)

verify_args=(
  verify
  --api-id api-123
  --authorizer-id auth-xyz
  --region us-east-1
  --route-key 'POST /webhook'
  --endpoint https://api.example.com/webhook
)

detach_args=(
  detach
  --api-id api-123
  --region us-east-1
  --route-key 'POST /webhook'
)

# --- attach happy path -------------------------------------------------------
reset_state
run_authorizer allow "${attach_args[@]}" >"$tmp_dir/out"
grep -q "attached auth-xyz to 'POST /webhook'" "$tmp_dir/out" ||
  fail "attach must report the new authorization"
grep -q "^apigatewayv2:get-routes .*RouteKey=='POST /webhook'" "$tmp_dir/calls" ||
  fail "attach must resolve the route id from the exact route key"
grep -q '^apigatewayv2:update-route .*--authorization-type CUSTOM --authorizer-id auth-xyz' "$tmp_dir/calls" ||
  fail "attach must set AuthorizationType=CUSTOM with the given authorizer"
grep -q '^curl args=.*--request POST https://api.example.com/webhook' "$tmp_dir/calls" ||
  fail "attach must probe the live webhook endpoint"
if grep -q '^apigatewayv2:update-route .*--authorization-type NONE' "$tmp_dir/calls"; then
  fail "a successful attach must not roll back"
fi
[[ "$(cat "$tmp_dir/state")" == "CUSTOM"$'\t'"auth-xyz" ]] ||
  fail "attach must leave the route on the compliance authorizer"

# --- attach rolls back when the authorizer denies -----------------------------
reset_state
if run_authorizer denying "${attach_args[@]}" >"$tmp_dir/out" 2>&1; then
  fail "attach must fail when the authorizer denies the unsigned probe"
fi
grep -q '^apigatewayv2:update-route .*--authorization-type NONE' "$tmp_dir/calls" ||
  fail "attach must restore an open route when the probe is denied"
[[ "$(cat "$tmp_dir/state")" == "NONE"$'\t'"None" ]] ||
  fail "a denied probe must leave the route open"

# --- attach fails without touching the route when it cannot be resolved -------
reset_state
if run_authorizer missing-route "${attach_args[@]}" >"$tmp_dir/out" 2>&1; then
  fail "attach must fail when no route matches the route key"
fi
if grep -q '^apigatewayv2:update-route ' "$tmp_dir/calls"; then
  fail "attach must not update a route it could not resolve"
fi

# --- attach fails when the endpoint is unreachable ---------------------------
reset_state
if run_authorizer unreachable "${attach_args[@]}" >"$tmp_dir/out" 2>&1; then
  fail "attach must fail when the webhook endpoint cannot be reached"
fi

# --- attach fails on an unexpected probe status ------------------------------
reset_state
if run_authorizer unexpected-status "${attach_args[@]}" >"$tmp_dir/out" 2>&1; then
  fail "attach must fail on a probe status it does not recognise"
fi

# --- attach fails when the route reports a different authorizer --------------
reset_state
if run_authorizer wrong-authorizer "${attach_args[@]}" >"$tmp_dir/out" 2>&1; then
  fail "attach must fail when the route reports another authorizer"
fi
grep -q 'expected .CUSTOM auth-xyz.' "$tmp_dir/out" ||
  fail "attach must report the mismatching authorization"
if grep -q '^curl args=' "$tmp_dir/calls"; then
  fail "attach must not probe traffic after an attachment mismatch"
fi

# --- verify is read only -----------------------------------------------------
reset_state
printf 'CUSTOM\tauth-xyz\n' >"$tmp_dir/state"
run_authorizer allow "${verify_args[@]}" >"$tmp_dir/out"
grep -q "OK, 'POST /webhook' uses auth-xyz" "$tmp_dir/out" ||
  fail "verify must confirm the attachment"
if grep -q '^apigatewayv2:update-route ' "$tmp_dir/calls"; then
  fail "verify must not modify the route"
fi

reset_state
printf 'CUSTOM\tauth-xyz\n' >"$tmp_dir/state"
if run_authorizer denying "${verify_args[@]}" >"$tmp_dir/out" 2>&1; then
  fail "verify must fail when the authorizer denies"
fi
grep -q 'detach --api-id api-123' "$tmp_dir/out" ||
  fail "a failing verify must name the rollback command"
if grep -q '^apigatewayv2:update-route ' "$tmp_dir/calls"; then
  fail "verify must not roll back on its own"
fi

reset_state
if run_authorizer allow "${verify_args[@]}" >"$tmp_dir/out" 2>&1; then
  fail "verify must fail when the route carries no authorizer"
fi

# --- detach ------------------------------------------------------------------
reset_state
printf 'CUSTOM\tauth-xyz\n' >"$tmp_dir/state"
run_authorizer allow "${detach_args[@]}" >"$tmp_dir/out"
grep -q '^apigatewayv2:update-route .*--authorization-type NONE' "$tmp_dir/calls" ||
  fail "detach must restore AuthorizationType=NONE"
[[ "$(cat "$tmp_dir/state")" == "NONE"$'\t'"None" ]] ||
  fail "detach must leave the route open"
if grep -q '^curl args=' "$tmp_dir/calls"; then
  fail "detach must not need the live endpoint"
fi

# --- argument handling -------------------------------------------------------
reset_state
if run_authorizer allow attach --api-id api-123 --region us-east-1 >"$tmp_dir/out" 2>&1; then
  fail "attach must require an authorizer id"
fi
reset_state
if run_authorizer allow attach --authorizer-id auth-xyz --region us-east-1 \
  --endpoint https://api.example.com/webhook >"$tmp_dir/out" 2>&1; then
  fail "attach must require an api id"
fi
reset_state
if run_authorizer allow bogus --api-id api-123 --region us-east-1 >"$tmp_dir/out" 2>&1; then
  fail "an unknown subcommand must fail"
fi

echo "PASS: webhook authorizer attachment"
