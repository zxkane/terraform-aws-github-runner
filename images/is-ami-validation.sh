#!/usr/bin/env bash
set -euo pipefail

IMDS_ROOT="${IMDS_ROOT:-http://169.254.169.254/latest}"

tmp_dir="$(mktemp -d)"
chmod 0700 "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

token_status="$(
  curl --silent --show-error --max-time 2 --retry 2 --retry-all-errors --retry-delay 1 \
    --output "$tmp_dir/token" \
    --write-out '%{http_code}' \
    -X PUT \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
    "$IMDS_ROOT/api/token"
)" || exit 2
[[ "$token_status" == "200" ]] || exit 2
token="$(<"$tmp_dir/token")"
[[ -n "$token" ]] || exit 2

tag_status="$(
  curl --silent --show-error --max-time 2 --retry 2 --retry-all-errors --retry-delay 1 \
    --output "$tmp_dir/tag" \
    --write-out '%{http_code}' \
    -H "X-aws-ec2-metadata-token: $token" \
    "$IMDS_ROOT/meta-data/tags/instance/ghr:ami_validation"
)" || exit 2

case "$tag_status" in
  200)
    [[ "$(<"$tmp_dir/tag")" == "true" ]]
    ;;
  404)
    exit 1
    ;;
  *)
    exit 2
    ;;
esac
