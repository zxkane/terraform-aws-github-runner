#!/usr/bin/env bash
set -euo pipefail

readonly CLEANUP_DEADLINE_MILLISECONDS="${AMI_VALIDATOR_CLEANUP_DEADLINE_MILLISECONDS:-120000}"
readonly CLEANUP_POLL_MILLISECONDS="${AMI_VALIDATOR_CLEANUP_POLL_MILLISECONDS:-3000}"
readonly AWS_CLI_TIMEOUT_SECONDS="${AMI_VALIDATOR_CLEANUP_AWS_CLI_TIMEOUT_SECONDS:-30}"
export AWS_CLI_TIMEOUT_SECONDS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # Resolved relative to this script at runtime.
source "$SCRIPT_DIR/aws-request-phase.sh"

: "${ARCHITECTURE:?ARCHITECTURE must be set}"
: "${AWS_REGION:?AWS_REGION must be set}"
: "${RELEASE_ID:?RELEASE_ID must be set}"
: "${VALIDATOR_INSTANCE_ID_FILE:?VALIDATOR_INSTANCE_ID_FILE must be set}"
: "${VALIDATOR_LAUNCH_MARKER_FILE:?VALIDATOR_LAUNCH_MARKER_FILE must be set}"

case "$ARCHITECTURE" in
  amd64 | arm64) ;;
  *)
    echo "Unsupported validator architecture" >&2
    exit 2
    ;;
esac

deadline=$(( $(monotonic_ms) + CLEANUP_DEADLINE_MILLISECONDS ))
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

declare -A instance_ids=()
declare -A termination_attempted=()

discover_instances() {
  local output_file="$tmp_dir/instances"
  : >"$output_file"

  run_aws_until "$deadline" default ec2 describe-instances \
    --region "$AWS_REGION" \
    --page-size 100 \
    --filters \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      "Name=tag:ghr:managed,Values=runner-ami-release" \
      "Name=tag:ghr:ami_role,Values=validator" \
      "Name=tag:ghr:release_id,Values=$RELEASE_ID" \
      "Name=tag:ghr:architecture,Values=$ARCHITECTURE" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text >"$output_file"

  local instance_id
  while IFS= read -r instance_id; do
    [[ -z "$instance_id" || "$instance_id" == "None" ]] && continue
    [[ "$instance_id" =~ ^i-[0-9a-f]{17}$ ]] || {
      echo "Validator lookup returned a malformed instance ID" >&2
      return 1
    }
    instance_ids["$instance_id"]=1
  done < <(tr '\t' '\n' <"$output_file")
}

terminate_new_instances() {
  local instance_id
  for instance_id in "${!instance_ids[@]}"; do
    [[ -z "${termination_attempted[$instance_id]+x}" ]] || continue
    termination_attempted["$instance_id"]=1
    echo "::add-mask::$instance_id"
    run_aws_until "$deadline" 1 ec2 terminate-instances \
      --region "$AWS_REGION" \
      --instance-ids "$instance_id" \
      >/dev/null
  done
}

bounded_sleep() {
  local remaining_ms=$((deadline - $(monotonic_ms)))
  ((remaining_ms > 0)) || return 1
  local sleep_ms="$CLEANUP_POLL_MILLISECONDS"
  ((sleep_ms <= remaining_ms)) || sleep_ms="$remaining_ms"
  ((sleep_ms > 0)) || return 1
  sleep "$(awk -v ms="$sleep_ms" 'BEGIN { printf "%.3f", ms / 1000 }')"
}

launch_state="PRELAUNCH"
if [[ -f "$VALIDATOR_INSTANCE_ID_FILE" ]]; then
  local_instance_id="$(<"$VALIDATOR_INSTANCE_ID_FILE")"
  [[ "$local_instance_id" =~ ^i-[0-9a-f]{17}$ ]] || {
    echo "Validator instance ID file is malformed" >&2
    exit 1
  }
  instance_ids["$local_instance_id"]=1
  launch_state="KNOWN"
elif [[ -f "$VALIDATOR_LAUNCH_MARKER_FILE" ]]; then
  launch_state="LAUNCH_UNKNOWN"
fi

case "$launch_state" in
  PRELAUNCH | KNOWN)
    discover_instances
    terminate_new_instances
    ;;
  LAUNCH_UNKNOWN)
    observed_instance=false
    while (($(monotonic_ms) < deadline)); do
      discover_instances
      if ((${#instance_ids[@]} > 0)); then
        observed_instance=true
      fi
      terminate_new_instances
      bounded_sleep || break
    done
    if [[ "$observed_instance" != "true" ]]; then
      echo "UNCONFIRMED_LAUNCH: no validator instance became visible before cleanup deadline" >&2
      exit 1
    fi
    ;;
esac

rm -f "$VALIDATOR_INSTANCE_ID_FILE" "$VALIDATOR_LAUNCH_MARKER_FILE"
