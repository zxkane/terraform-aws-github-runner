#!/usr/bin/env bash
set -euo pipefail

readonly CLEANUP_DEADLINE_MILLISECONDS="${AMI_BUILDER_CLEANUP_DEADLINE_MILLISECONDS:-120000}"
readonly AWS_CLI_TIMEOUT_SECONDS="${AMI_BUILDER_CLEANUP_AWS_CLI_TIMEOUT_SECONDS:-30}"
export AWS_CLI_TIMEOUT_SECONDS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # Resolved relative to this script at runtime.
source "$SCRIPT_DIR/aws-request-phase.sh"

: "${ARCHITECTURE:?ARCHITECTURE must be set}"
: "${AWS_REGION:?AWS_REGION must be set}"
: "${RELEASE_ID:?RELEASE_ID must be set}"

case "$ARCHITECTURE" in
  amd64 | arm64) ;;
  *)
    echo "Unsupported builder architecture" >&2
    exit 2
    ;;
esac

deadline=$(( $(monotonic_ms) + CLEANUP_DEADLINE_MILLISECONDS ))
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

output_file="$tmp_dir/instances"
run_aws_until "$deadline" default ec2 describe-instances \
  --region "$AWS_REGION" \
  --page-size 100 \
  --filters \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    "Name=tag:ghr:managed,Values=runner-ami-release" \
    "Name=tag:ghr:ami_role,Values=builder" \
    "Name=tag:ghr:release_id,Values=$RELEASE_ID" \
    "Name=tag:ghr:architecture,Values=$ARCHITECTURE" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text >"$output_file"

declare -A instance_ids=()
while IFS= read -r instance_id; do
  [[ -z "$instance_id" || "$instance_id" == "None" ]] && continue
  [[ "$instance_id" =~ ^i-[0-9a-f]{17}$ ]] || {
    echo "Builder lookup returned a malformed instance ID" >&2
    exit 1
  }
  instance_ids["$instance_id"]=1
done < <(tr '\t' '\n' <"$output_file")

termination_failed=false
for instance_id in "${!instance_ids[@]}"; do
  echo "::add-mask::$instance_id"
  if ! run_aws_until "$deadline" 1 ec2 terminate-instances \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    >/dev/null; then
    termination_failed=true
  fi
done

[[ "$termination_failed" == "false" ]]
