#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # Resolved relative to this test at runtime.
source "$SCRIPT_DIR/ami-log-sanitizer.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
input="$tmp_dir/packer.log"
account_id="$(printf '1%.0s' {1..12})"

printf '%s\n' \
  "account=$account_id ami=ami-0123456789abcdef0 instance=i-0123456789abcdef0" \
  'subnet=subnet-0123456789abcdef0 sg=sg-0123456789abcdef0 vpc=vpc-0123456789abcdef0' \
  'snapshot=snap-0123456789abcdef0 volume=vol-0123456789abcdef0 eni=eni-0123456789abcdef0' \
  >"$input"

sanitized="$(sanitize_ami_build_log "$input")"

for marker in \
  '<masked-account>' \
  '<masked-ami>' \
  '<masked-instance>' \
  '<masked-resource>'; do
  grep -Fq "$marker" <<<"$sanitized" || {
    echo "FAIL: missing sanitizer marker $marker" >&2
    exit 1
  }
done

if grep -Eq \
  '(^|[^0-9])[0-9]{12}([^0-9]|$)|ami-[0-9a-f]{8,17}|i-[0-9a-f]{8,17}|(subnet|sg|vpc|snap|vol|eni)-[0-9a-f]{8,17}' \
  <<<"$sanitized"; then
  echo "FAIL: sanitizer replayed an AWS identifier" >&2
  exit 1
fi

echo "PASS: AMI build log sanitizer"
