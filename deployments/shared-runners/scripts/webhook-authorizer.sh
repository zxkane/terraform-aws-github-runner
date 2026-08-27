#!/usr/bin/env bash
# Attach, detach or verify the always-allow authorizer on the GitHub webhook route.
#
# A Lambda authorizer cannot verify the GitHub HMAC — no API Gateway authorizer
# payload format carries the request body, and the signature covers that body.
# Signature verification stays in the webhook lambda; this authorizer exists to
# satisfy the API Gateway authorization control and always allows.
#
# The upstream webhook module ignores the route's authorizer attributes on
# purpose, so assignment happens here instead of on the route resource. That also
# avoids a Terraform dependency cycle: the authorizer needs the API id and the
# route needs the authorizer id. `update-route` updates the route in place, so it
# is never recreated and no delivery window opens.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  webhook-authorizer.sh attach --api-id ID --authorizer-id ID --region REGION \
                               --route-key 'POST /webhook' --endpoint URL
  webhook-authorizer.sh verify --api-id ID --authorizer-id ID --region REGION \
                               --route-key 'POST /webhook' --endpoint URL
  webhook-authorizer.sh detach --api-id ID --region REGION --route-key 'POST /webhook'
EOF
  exit 2
}

die() {
  echo "webhook-authorizer: $*" >&2
  exit 1
}

COMMAND="${1:-}"
shift || usage

API_ID=""
AUTHORIZER_ID=""
REGION=""
ROUTE_KEY="POST /webhook"
ENDPOINT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-id)
      API_ID="${2:?--api-id needs a value}"
      shift 2
      ;;
    --authorizer-id)
      AUTHORIZER_ID="${2:?--authorizer-id needs a value}"
      shift 2
      ;;
    --region)
      REGION="${2:?--region needs a value}"
      shift 2
      ;;
    --route-key)
      ROUTE_KEY="${2:?--route-key needs a value}"
      shift 2
      ;;
    --endpoint)
      ENDPOINT="${2:?--endpoint needs a value}"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$API_ID" ]] || die "--api-id is required"
[[ -n "$REGION" ]] || die "--region is required"

resolve_route_id() {
  local route_id
  route_id="$(aws apigatewayv2 get-routes \
    --api-id "$API_ID" \
    --region "$REGION" \
    --query "Items[?RouteKey=='${ROUTE_KEY}'].RouteId | [0]" \
    --output text)"
  [[ -n "$route_id" && "$route_id" != "None" ]] || die "no route matches '${ROUTE_KEY}' on API ${API_ID}"
  printf '%s' "$route_id"
}

read_authorization() {
  aws apigatewayv2 get-route \
    --api-id "$API_ID" \
    --route-id "$1" \
    --region "$REGION" \
    --query '[AuthorizationType, AuthorizerId]' \
    --output text
}

set_authorization_none() {
  aws apigatewayv2 update-route \
    --api-id "$API_ID" \
    --route-id "$1" \
    --region "$REGION" \
    --authorization-type NONE >/dev/null
}

assert_attached() {
  local observed
  observed="$(read_authorization "$1")"
  [[ "$observed" == "CUSTOM"$'\t'"$AUTHORIZER_ID" ]] ||
    die "route '${ROUTE_KEY}' reports '${observed}', expected 'CUSTOM ${AUTHORIZER_ID}'"
}

# An unsigned delivery must still reach the webhook lambda, which rejects it on
# the HMAC check. API Gateway answers 403 when an authorizer denies, so a 403
# here means the authorizer would drop real GitHub deliveries as well.
probe_delivery_path() {
  local status
  status="$(curl --silent --show-error \
    --output /dev/null \
    --write-out '%{http_code}' \
    --max-time 20 \
    --request POST "$ENDPOINT" \
    --header 'content-type: application/json' \
    --header 'x-github-event: ping' \
    --data '{}')" || die "could not reach ${ENDPOINT}"

  case "$status" in
    401 | 500)
      echo "webhook-authorizer: unsigned probe answered ${status} by the webhook lambda"
      ;;
    403)
      echo "webhook-authorizer: unsigned probe answered 403, the authorizer is denying" >&2
      return 1
      ;;
    *)
      die "unsigned probe returned unexpected HTTP ${status} from ${ENDPOINT}"
      ;;
  esac
}

case "$COMMAND" in
  attach)
    [[ -n "$AUTHORIZER_ID" ]] || die "--authorizer-id is required for attach"
    [[ -n "$ENDPOINT" ]] || die "--endpoint is required for attach"

    route_id="$(resolve_route_id)"
    previous="$(read_authorization "$route_id")"

    aws apigatewayv2 update-route \
      --api-id "$API_ID" \
      --route-id "$route_id" \
      --region "$REGION" \
      --authorization-type CUSTOM \
      --authorizer-id "$AUTHORIZER_ID" >/dev/null

    assert_attached "$route_id"

    if ! probe_delivery_path; then
      set_authorization_none "$route_id"
      die "restored '${ROUTE_KEY}' to AuthorizationType=NONE, authorizer ${AUTHORIZER_ID} rejects traffic"
    fi

    echo "webhook-authorizer: attached ${AUTHORIZER_ID} to '${ROUTE_KEY}' (was ${previous})"
    ;;

  verify)
    [[ -n "$AUTHORIZER_ID" ]] || die "--authorizer-id is required for verify"
    [[ -n "$ENDPOINT" ]] || die "--endpoint is required for verify"

    route_id="$(resolve_route_id)"
    assert_attached "$route_id"

    if ! probe_delivery_path; then
      die "run 'webhook-authorizer.sh detach --api-id ${API_ID} --region ${REGION}' to restore deliveries"
    fi

    echo "webhook-authorizer: OK, '${ROUTE_KEY}' uses ${AUTHORIZER_ID} and deliveries still reach the webhook lambda"
    ;;

  detach)
    route_id="$(resolve_route_id)"
    set_authorization_none "$route_id"
    echo "webhook-authorizer: restored '${ROUTE_KEY}' to AuthorizationType=NONE"
    ;;

  *)
    usage
    ;;
esac
