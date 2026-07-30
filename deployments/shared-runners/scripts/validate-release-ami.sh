#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly VALIDATION_DEADLINE_SECONDS="${AMI_VALIDATION_DEADLINE_SECONDS:-1200}"
readonly REGISTRATION_DEADLINE_SECONDS="${AMI_REGISTRATION_DEADLINE_SECONDS:-600}"
readonly PREFLIGHT_DEADLINE_SECONDS="${AMI_VALIDATION_PREFLIGHT_DEADLINE_SECONDS:-120}"
readonly LAUNCH_DEADLINE_SECONDS="${AMI_VALIDATION_LAUNCH_DEADLINE_SECONDS:-120}"
readonly TAG_DEADLINE_SECONDS="${AMI_VALIDATION_TAG_DEADLINE_SECONDS:-120}"
readonly CLEANUP_DEADLINE_SECONDS="${AMI_VALIDATION_CLEANUP_DEADLINE_SECONDS:-120}"
readonly POLL_SECONDS="${AMI_VALIDATION_POLL_SECONDS:-10}"
readonly MAX_POLL_SECONDS="${AMI_VALIDATION_MAX_POLL_SECONDS:-30}"
readonly AWS_CLI_TIMEOUT_SECONDS="${AMI_VALIDATION_AWS_CLI_TIMEOUT_SECONDS:-30}"

: "${ARCHITECTURE:?ARCHITECTURE must be amd64 or arm64}"
: "${AWS_REGION:?AWS_REGION must be set}"
: "${RELEASE_ID:?RELEASE_ID must be set}"
: "${SOURCE_REVISION:?SOURCE_REVISION must be set}"
: "${AMI_ID_FILE:?AMI_ID_FILE must be set}"
: "${AMI_VALIDATOR_INSTANCE_PROFILE:?AMI_VALIDATOR_INSTANCE_PROFILE must be set}"
: "${AMI_VALIDATOR_SECURITY_GROUP_ID:?AMI_VALIDATOR_SECURITY_GROUP_ID must be set}"
: "${AMI_SUBNET_ID:?AMI_SUBNET_ID must be set}"
: "${VALIDATOR_INSTANCE_ID_FILE:?VALIDATOR_INSTANCE_ID_FILE must be set}"
: "${VALIDATOR_LAUNCH_MARKER_FILE:?VALIDATOR_LAUNCH_MARKER_FILE must be set}"

ami_id="$(<"$AMI_ID_FILE")"
[[ "$ami_id" =~ ^ami-[0-9a-f]{17}$ ]] || {
  echo "AMI ID file is malformed" >&2
  exit 2
}
echo "::add-mask::$ami_id"

case "$ARCHITECTURE" in
  amd64)
    ec2_architecture="x86_64"
    instance_type="t3.large"
    ;;
  arm64)
    ec2_architecture="arm64"
    instance_type="t4g.large"
    ;;
  *)
    echo "Unsupported architecture" >&2
    exit 2
    ;;
esac

tmp_dir="$(mktemp -d)"
chmod 0700 "$tmp_dir"
instance_id=""
validation_passed=false
validation_assertions_passed=false
candidate_verified=false

now_ms() {
  awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime
}

deadline_after() {
  printf '%s\n' "$(($(now_ms) + $1 * 1000))"
}

run_aws_until() {
  local deadline="$1"
  shift

  local remaining_ms=$((deadline - $(now_ms)))
  ((remaining_ms > 0)) || return 124

  local cli_timeout=$(((remaining_ms + 999) / 1000))
  ((cli_timeout <= AWS_CLI_TIMEOUT_SECONDS)) || cli_timeout="$AWS_CLI_TIMEOUT_SECONDS"
  local request_ms="$remaining_ms"
  ((request_ms <= AWS_CLI_TIMEOUT_SECONDS * 1000)) ||
    request_ms=$((AWS_CLI_TIMEOUT_SECONDS * 1000))
  local request_seconds
  request_seconds="$(awk -v milliseconds="$request_ms" 'BEGIN { printf "%.3f", milliseconds / 1000 }')"

  timeout --signal=KILL "${request_seconds}s" \
    aws "$@" \
    --cli-connect-timeout "$cli_timeout" \
    --cli-read-timeout "$cli_timeout"
}

run_aws_once_until() {
  local deadline="$1"
  shift

  AWS_MAX_ATTEMPTS=1 run_aws_until "$deadline" "$@"
}

bounded_poll_sleep() {
  local deadline="$1"
  local attempt="$2"
  local remaining_ms=$((deadline - $(now_ms)))
  ((remaining_ms > 0)) || return 1

  local sleep_ms
  sleep_ms="$(
    awk \
      -v base="$POLL_SECONDS" \
      -v cap="$MAX_POLL_SECONDS" \
      -v attempt="$attempt" \
      -v remaining_ms="$remaining_ms" \
      'BEGIN {
        exponent = attempt < 6 ? attempt : 6
        delay_ms = base * (2 ^ exponent) * 1000
        cap_ms = cap * 1000
        if (delay_ms > cap_ms) delay_ms = cap_ms
        if (delay_ms > remaining_ms) delay_ms = remaining_ms
        printf "%.0f", delay_ms
      }'
  )"
  ((sleep_ms > 0)) || return 1
  sleep "$(awk -v milliseconds="$sleep_ms" 'BEGIN { printf "%.3f", milliseconds / 1000 }')"
}

cleanup() {
  local rc=$?
  local cleanup_deadline
  trap - EXIT
  cleanup_deadline="$(deadline_after "$CLEANUP_DEADLINE_SECONDS")"

  if [[ "$candidate_verified" == "true" && "$validation_assertions_passed" != "true" ]]; then
    run_aws_once_until "$cleanup_deadline" ec2 create-tags \
      --region "$AWS_REGION" \
      --resources "$ami_id" \
      --tags Key=ghr:validation_status,Value=failed >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_dir"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

description_file="$tmp_dir/image.json"
preflight_deadline="$(deadline_after "$PREFLIGHT_DEADLINE_SECONDS")"
run_aws_until "$preflight_deadline" ec2 describe-images \
  --region "$AWS_REGION" \
  --owners self \
  --image-ids "$ami_id" \
  --output json >"$description_file" ||
  {
    echo "AMI preflight describe did not complete before its deadline" >&2
    exit 1
  }

jq -e \
  --arg ami "$ami_id" \
  --arg architecture "$ec2_architecture" \
  --arg release "$RELEASE_ID" \
  --arg source "$SOURCE_REVISION" \
  '
    .Images | length == 1
    and .[0].ImageId == $ami
    and .[0].State == "available"
    and .[0].Architecture == $architecture
    and .[0].ImdsSupport == "v2.0"
    and ([.[0].BlockDeviceMappings[]? | .Ebs? | select(. != null)] | length > 0)
    and all(.[0].BlockDeviceMappings[]? | .Ebs? | select(. != null); .Encrypted == true)
    and ([.[0].Tags[]? | select(.Key == "ghr:managed") | .Value] == ["runner-ami-release"])
    and ([.[0].Tags[]? | select(.Key == "ghr:release_id") | .Value] == [$release])
    and ([.[0].Tags[]? | select(.Key == "ghr:architecture") | .Value] == [$architecture | if . == "x86_64" then "amd64" else . end])
    and ([.[0].Tags[]? | select(.Key == "ghr:ami_role") | .Value] == ["builder"])
    and ([.[0].Tags[]? | select(.Key == "ghr:source_revision") | .Value] == [$source])
    and ([.[0].Tags[]? | select(.Key == "ghr:validation_status") | .Value] == ["candidate"])
  ' "$description_file" >/dev/null
candidate_verified=true

cat >"$tmp_dir/user-data.sh" <<'EOF'
#!/usr/bin/env bash
shutdown -h +110
EOF

instance_file="$tmp_dir/instance.txt"
validator_client_token="ghr-validator-${RELEASE_ID}-${ARCHITECTURE}"
launch_deadline="$(deadline_after "$LAUNCH_DEADLINE_SECONDS")"
umask 077
printf 'attempted\n' >"$VALIDATOR_LAUNCH_MARKER_FILE"
run_aws_once_until "$launch_deadline" ec2 run-instances \
  --region "$AWS_REGION" \
  --client-token "$validator_client_token" \
  --image-id "$ami_id" \
  --instance-type "$instance_type" \
  --subnet-id "$AMI_SUBNET_ID" \
  --security-group-ids "$AMI_VALIDATOR_SECURITY_GROUP_ID" \
  --iam-instance-profile "Name=$AMI_VALIDATOR_INSTANCE_PROFILE" \
  --no-associate-public-ip-address \
  --metadata-options "HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=1,InstanceMetadataTags=enabled" \
  --instance-initiated-shutdown-behavior terminate \
  --user-data "file://$tmp_dir/user-data.sh" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=ghr:managed,Value=runner-ami-release},{Key=ghr:ami_role,Value=validator},{Key=ghr:ami_validation,Value=true},{Key=ghr:release_id,Value=$RELEASE_ID},{Key=ghr:architecture,Value=$ARCHITECTURE}]" \
    "ResourceType=volume,Tags=[{Key=ghr:managed,Value=runner-ami-release},{Key=ghr:ami_role,Value=validator},{Key=ghr:release_id,Value=$RELEASE_ID},{Key=ghr:architecture,Value=$ARCHITECTURE}]" \
  --query 'Instances[0].InstanceId' \
  --output text >"$instance_file" ||
  {
    echo "Validator launch did not complete before its request deadline" >&2
    exit 1
  }
instance_id="$(<"$instance_file")"
[[ "$instance_id" =~ ^i-[0-9a-f]{17}$ ]] || {
  echo "Validator launch did not return an instance ID" >&2
  exit 1
}
echo "::add-mask::$instance_id"
printf '%s\n' "$instance_id" >"$VALIDATOR_INSTANCE_ID_FILE"
chmod 0600 "$VALIDATOR_INSTANCE_ID_FILE"

registration_deadline="$(deadline_after "$REGISTRATION_DEADLINE_SECONDS")"
registration_attempt=0
while (($(now_ms) < registration_deadline)); do
  ping_status="$(
    run_aws_until "$registration_deadline" ssm describe-instance-information \
      --region "$AWS_REGION" \
      --filters "Key=InstanceIds,Values=$instance_id" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || true
  )"
  [[ "$ping_status" == "Online" ]] && break
  bounded_poll_sleep "$registration_deadline" "$registration_attempt" || break
  ((registration_attempt += 1))
done
[[ "${ping_status:-}" == "Online" ]] || {
  echo "Validator did not register with Systems Manager" >&2
  exit 1
}

script_base64="$(base64 -w 0 "$SCRIPT_DIR/validate-ami-instance.sh")"
jq -n \
  --arg command "printf '%s' '$script_base64' | base64 -d > /tmp/validate-ami-instance.sh && chmod 0700 /tmp/validate-ami-instance.sh && /tmp/validate-ami-instance.sh '$ARCHITECTURE'" \
  '{commands: [$command], executionTimeout: ["1200"]}' >"$tmp_dir/parameters.json"

command_file="$tmp_dir/command.txt"
validation_deadline="$(deadline_after "$VALIDATION_DEADLINE_SECONDS")"
run_aws_once_until "$validation_deadline" ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --parameters "file://$tmp_dir/parameters.json" \
  --timeout-seconds "$VALIDATION_DEADLINE_SECONDS" \
  --query 'Command.CommandId' \
  --output text >"$command_file" ||
  {
    echo "Run Command submission did not complete before its deadline" >&2
    exit 1
  }
command_id="$(<"$command_file")"
[[ "$command_id" =~ ^[0-9a-f-]{36}$ ]] || {
  echo "Run Command did not return a command ID" >&2
  exit 1
}
echo "::add-mask::$command_id"

validation_attempt=0
status=""
while (($(now_ms) < validation_deadline)); do
  invocation_file="$tmp_dir/invocation.json"
  if ! run_aws_until "$validation_deadline" ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --output json >"$invocation_file" 2>"$tmp_dir/invocation.err"; then
    if grep -q "InvocationDoesNotExist" "$tmp_dir/invocation.err"; then
      bounded_poll_sleep "$validation_deadline" "$validation_attempt" || break
      ((validation_attempt += 1))
      continue
    fi
    cat "$tmp_dir/invocation.err" >&2
    exit 1
  fi

  status="$(jq -r '.Status // empty' "$invocation_file")"
  case "$status" in
    Pending | InProgress | Delayed)
      bounded_poll_sleep "$validation_deadline" "$validation_attempt" || break
      ((validation_attempt += 1))
      ;;
    Success)
      [[ "$(jq -r '.ResponseCode' "$invocation_file")" == "0" ]] || {
        echo "Validation returned a nonzero response code" >&2
        exit 1
      }
      break
      ;;
    Cancelled | Cancelling | Failed | TimedOut | "Delivery Timed Out" | "Execution Timed Out")
      jq -r '.StandardErrorContent // empty' "$invocation_file" >&2
      exit 1
      ;;
    *)
      echo "Validation returned an unknown Run Command status" >&2
      exit 1
      ;;
  esac
done
[[ "$status" == "Success" ]] || {
  echo "Validation exceeded its 20-minute deadline" >&2
  exit 1
}
validation_assertions_passed=true

tag_deadline="$(deadline_after "$TAG_DEADLINE_SECONDS")"
run_aws_once_until "$tag_deadline" ec2 create-tags \
  --region "$AWS_REGION" \
  --resources "$ami_id" \
  --tags Key=ghr:validation_status,Value=passed >/dev/null 2>&1 || true

tag_attempt=0
while (($(now_ms) < tag_deadline)); do
  if run_aws_until "$tag_deadline" ec2 describe-images \
    --region "$AWS_REGION" \
    --owners self \
    --image-ids "$ami_id" \
    --output json >"$description_file" 2>/dev/null &&
    jq -e \
      --arg ami "$ami_id" \
      '
        .Images | length == 1
        and .[0].ImageId == $ami
        and ([.[0].Tags[]? | select(.Key == "ghr:validation_status") | .Value] == ["passed"])
      ' "$description_file" >/dev/null; then
    validation_passed=true
    break
  fi
  bounded_poll_sleep "$tag_deadline" "$tag_attempt" || break
  ((tag_attempt += 1))
done
[[ "$validation_passed" == "true" ]] || {
  echo "Passed validation tag did not become readable before the deadline" >&2
  exit 1
}
echo "Final AMI validation passed for $ARCHITECTURE"
