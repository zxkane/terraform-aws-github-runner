#!/usr/bin/env bash
set -euo pipefail

readonly DEADLINE_SECONDS="${AMI_CHANNEL_DEADLINE_SECONDS:-120}"
readonly POLL_SECONDS="${AMI_CHANNEL_POLL_SECONDS:-3}"
readonly MAX_POLL_SECONDS="${AMI_CHANNEL_MAX_POLL_SECONDS:-15}"
readonly AWS_CLI_TIMEOUT_SECONDS="${AMI_CHANNEL_AWS_CLI_TIMEOUT_SECONDS:-15}"
readonly MAX_CANDIDATE_AGE_SECONDS=$((7 * 24 * 60 * 60))
WRITE_RESULT="unknown"
CHANNEL_WAIT_RESULT="unknown"
CHANNEL_ACTIVE=""
CHANNEL_PREVIOUS=""
CHANNEL_RECOVERY=""

die() {
  echo "AMI channel error: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  ami-channel.sh promote --build-run-id ID --build-run-attempt ATTEMPT --source-revision SHA
  ami-channel.sh rollback

Required environment:
  ARCHITECTURE  amd64 or arm64
  AWS_REGION    target AWS region
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
command="$1"
shift

: "${ARCHITECTURE:?ARCHITECTURE must be amd64 or arm64}"
: "${AWS_REGION:?AWS_REGION must be set}"

case "$ARCHITECTURE" in
  amd64)
    readonly EC2_ARCHITECTURE="x86_64"
    readonly ACTIVE_PARAMETER="/github-action-runners/gh-runner/linux-amd64/runners/config/ami_id"
    readonly PREVIOUS_PARAMETER="/github-action-runners/gh-runner/linux-amd64/runners/config/ami_previous_id"
    readonly RECOVERY_PARAMETER="/github-action-runners/gh-runner/linux-amd64/runners/config/ami_recovery_id"
    readonly LAUNCH_TEMPLATE_NAME="gh-runner-linux-amd64-action-runner"
    ;;
  arm64)
    readonly EC2_ARCHITECTURE="arm64"
    readonly ACTIVE_PARAMETER="/github-action-runners/gh-runner/linux-arm64/runners/config/ami_id"
    readonly PREVIOUS_PARAMETER="/github-action-runners/gh-runner/linux-arm64/runners/config/ami_previous_id"
    readonly RECOVERY_PARAMETER="/github-action-runners/gh-runner/linux-arm64/runners/config/ami_recovery_id"
    readonly LAUNCH_TEMPLATE_NAME="gh-runner-linux-arm64-action-runner"
    ;;
  *)
    die "unsupported architecture"
    ;;
esac

now_ms() {
  awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime
}

deadline_epoch() {
  printf '%s\n' "$(($(now_ms) + DEADLINE_SECONDS * 1000))"
}

run_aws_until() {
  local deadline="$1"
  local max_attempts="$2"
  shift 2

  local remaining_ms=$((deadline - $(now_ms)))
  ((remaining_ms > 0)) || return 124

  local cli_timeout=$(((remaining_ms + 999) / 1000))
  ((cli_timeout <= AWS_CLI_TIMEOUT_SECONDS)) || cli_timeout="$AWS_CLI_TIMEOUT_SECONDS"
  local request_ms="$remaining_ms"
  ((request_ms <= AWS_CLI_TIMEOUT_SECONDS * 1000)) ||
    request_ms=$((AWS_CLI_TIMEOUT_SECONDS * 1000))
  local request_seconds
  request_seconds="$(awk -v milliseconds="$request_ms" 'BEGIN { printf "%.3f", milliseconds / 1000 }')"

  if [[ "$max_attempts" == "1" ]]; then
    AWS_MAX_ATTEMPTS=1 timeout --signal=KILL "${request_seconds}s" \
      aws "$@" \
      --cli-connect-timeout "$cli_timeout" \
      --cli-read-timeout "$cli_timeout"
  else
    timeout --signal=KILL "${request_seconds}s" \
      aws "$@" \
      --cli-connect-timeout "$cli_timeout" \
      --cli-read-timeout "$cli_timeout"
  fi
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

read_parameter() {
  local name="$1"
  local deadline="${2:-$(deadline_epoch)}"

  run_aws_until "$deadline" default ssm get-parameter \
    --region "$AWS_REGION" \
    --name "$name" \
    --query 'Parameter.Value' \
    --output text
}

wait_for_parameter() {
  local name="$1"
  local expected="$2"
  local known_before="$3"
  local deadline="$4"
  local observed
  local saw_source=false
  local attempt=0

  while (($(now_ms) < deadline)); do
    if observed="$(read_parameter "$name" "$deadline" 2>/dev/null)"; then
      if [[ "$observed" == "$expected" ]]; then
        WRITE_RESULT="applied"
        return 0
      elif [[ "$observed" == "$known_before" ]]; then
        saw_source=true
      else
        WRITE_RESULT="drift"
        return 1
      fi
    fi
    bounded_poll_sleep "$deadline" "$attempt" || break
    ((attempt += 1))
  done

  if [[ "$saw_source" == "true" ]]; then
    WRITE_RESULT="unchanged"
  else
    WRITE_RESULT="unknown"
  fi
  return 1
}

write_parameter() {
  local name="$1"
  local value="$2"
  local known_before="$3"
  local deadline
  deadline="$(deadline_epoch)"
  WRITE_RESULT="unknown"

  run_aws_until "$deadline" 1 ssm put-parameter \
    --region "$AWS_REGION" \
    --name "$name" \
    --type String \
    --data-type aws:ec2:image \
    --value "$value" \
    --overwrite >/dev/null 2>&1 || true

  # PutParameter validates aws:ec2:image values asynchronously, and a network
  # timeout can happen after the write applied. Only bounded read-back can
  # classify the single write attempt safely.
  wait_for_parameter "$name" "$value" "$known_before" "$deadline"
}

read_channels() {
  local deadline="${1:-$(deadline_epoch)}"
  local active
  local previous
  local recovery

  active="$(read_parameter "$ACTIVE_PARAMETER" "$deadline" 2>/dev/null)" || return 1
  previous="$(read_parameter "$PREVIOUS_PARAMETER" "$deadline" 2>/dev/null)" || return 1
  recovery="$(read_parameter "$RECOVERY_PARAMETER" "$deadline" 2>/dev/null)" || return 1
  echo "::add-mask::$active"
  echo "::add-mask::$previous"
  echo "::add-mask::$recovery"
  CHANNEL_ACTIVE="$active"
  CHANNEL_PREVIOUS="$previous"
  CHANNEL_RECOVERY="$recovery"
}

wait_for_channels() {
  local expected_active="$1"
  local expected_previous="$2"
  local expected_recovery="$3"
  local source_active="$4"
  local source_previous="$5"
  local source_recovery="$6"
  local deadline
  local saw_source=false
  local attempt=0
  deadline="$(deadline_epoch)"
  CHANNEL_WAIT_RESULT="unknown"

  while (($(now_ms) < deadline)); do
    if read_channels "$deadline"; then
      if [[ "$CHANNEL_ACTIVE" == "$expected_active" &&
        "$CHANNEL_PREVIOUS" == "$expected_previous" &&
        "$CHANNEL_RECOVERY" == "$expected_recovery" ]]; then
        CHANNEL_WAIT_RESULT="applied"
        return 0
      elif [[ "$CHANNEL_ACTIVE" == "$source_active" &&
        "$CHANNEL_PREVIOUS" == "$source_previous" &&
        "$CHANNEL_RECOVERY" == "$source_recovery" ]]; then
        saw_source=true
      else
        CHANNEL_WAIT_RESULT="drift"
        return 1
      fi
    fi
    bounded_poll_sleep "$deadline" "$attempt" || break
    ((attempt += 1))
  done

  if [[ "$saw_source" == "true" ]]; then
    CHANNEL_WAIT_RESULT="unchanged"
  else
    CHANNEL_WAIT_RESULT="unknown"
  fi
  return 1
}

resolved_launch_template_image() {
  local deadline="${1:-$(deadline_epoch)}"

  run_aws_until "$deadline" default ec2 describe-launch-template-versions \
    --region "$AWS_REGION" \
    --launch-template-name "$LAUNCH_TEMPLATE_NAME" \
    --versions "\$Default" \
    --resolve-alias \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId' \
    --output text
}

wait_for_launch_template() {
  local expected="$1"
  local deadline
  local observed
  local attempt=0
  deadline="$(deadline_epoch)"

  while (($(now_ms) < deadline)); do
    if observed="$(resolved_launch_template_image "$deadline" 2>/dev/null)" && [[ "$observed" == "$expected" ]]; then
      return 0
    fi
    bounded_poll_sleep "$deadline" "$attempt" || break
    ((attempt += 1))
  done
  return 1
}

describe_owned_image() {
  local deadline
  deadline="$(deadline_epoch)"

  run_aws_until "$deadline" default ec2 describe-images \
    --region "$AWS_REGION" \
    --owners self \
    --image-ids "$1" \
    --output json
}

validate_channel_image() {
  local image_id="$1"
  local response

  response="$(describe_owned_image "$image_id" 2>/dev/null)" || return 1
  jq -e \
    --arg image_id "$image_id" \
    --arg architecture "$EC2_ARCHITECTURE" \
    '
      .Images | length == 1
      and .[0].ImageId == $image_id
      and .[0].Architecture == $architecture
      and .[0].State == "available"
    ' <<<"$response" >/dev/null
}

protect_recovery_source() {
  local recovery_source="$1"
  local expected_active="$2"
  local expected_previous="$3"
  local recovery_before

  recovery_before="$(read_parameter "$RECOVERY_PARAMETER")" ||
    die "recovery channel is unreadable"
  echo "::add-mask::$recovery_before"

  if [[ "$recovery_before" != "$recovery_source" ]]; then
    if ! write_parameter "$RECOVERY_PARAMETER" "$recovery_source" "$recovery_before"; then
      die "recovery protection could not be established"
    fi
  fi

  if ! read_channels ||
    [[ "$CHANNEL_ACTIVE" != "$expected_active" ]] ||
    [[ "$CHANNEL_PREVIOUS" != "$expected_previous" ]] ||
    [[ "$CHANNEL_RECOVERY" != "$recovery_source" ]]; then
    die "EXTERNAL_DRIFT: channels changed while establishing recovery protection"
  fi
}

compensate_promotion() {
  local active_before="$1"
  local previous_before="$2"
  local candidate="$3"

  if ! read_channels; then
    echo "COMPENSATION_FAILED: channels are unreadable before compensation" >&2
    return 1
  fi

  if [[ "$CHANNEL_RECOVERY" != "$previous_before" ]]; then
    echo "COMPENSATION_FAILED: recovery channel drifted before compensation" >&2
    return 1
  fi

  if [[ "$CHANNEL_ACTIVE" == "$active_before" &&
    "$CHANNEL_PREVIOUS" == "$previous_before" ]]; then
    return 0
  fi

  if [[ "$CHANNEL_ACTIVE" == "$candidate" && "$CHANNEL_PREVIOUS" == "$active_before" ]]; then
    if ! write_parameter "$ACTIVE_PARAMETER" "$active_before" "$candidate"; then
      echo "COMPENSATION_FAILED: active channel could not be restored" >&2
      return 1
    fi
    if ! read_channels ||
      [[ "$CHANNEL_ACTIVE" != "$active_before" ]] ||
      [[ "$CHANNEL_PREVIOUS" != "$active_before" ]] ||
      [[ "$CHANNEL_RECOVERY" != "$previous_before" ]]; then
      echo "COMPENSATION_FAILED: channels drifted after active restoration" >&2
      return 1
    fi
  elif [[ "$CHANNEL_ACTIVE" != "$active_before" || "$CHANNEL_PREVIOUS" != "$active_before" ]]; then
    echo "COMPENSATION_FAILED: refusing to overwrite an unexpected channel tuple" >&2
    return 1
  fi

  if [[ "$previous_before" == "$active_before" ]]; then
    return 0
  fi

  if ! read_channels ||
    [[ "$CHANNEL_ACTIVE" != "$active_before" ]] ||
    [[ "$CHANNEL_PREVIOUS" != "$active_before" ]] ||
    [[ "$CHANNEL_RECOVERY" != "$previous_before" ]]; then
    echo "COMPENSATION_FAILED: channels drifted before previous restoration" >&2
    return 1
  fi
  if ! write_parameter "$PREVIOUS_PARAMETER" "$previous_before" "$active_before"; then
    echo "COMPENSATION_FAILED: previous channel could not be restored" >&2
    return 1
  fi
  if ! read_channels ||
    [[ "$CHANNEL_ACTIVE" != "$active_before" ]] ||
    [[ "$CHANNEL_PREVIOUS" != "$previous_before" ]] ||
    [[ "$CHANNEL_RECOVERY" != "$previous_before" ]]; then
    echo "COMPENSATION_FAILED: original channel tuple was not restored" >&2
    return 1
  fi
}

fail_after_promotion_write() {
  local reason="$1"
  local active_before="$2"
  local previous_before="$3"
  local candidate="$4"

  compensate_promotion "$active_before" "$previous_before" "$candidate" ||
    die "COMPENSATION_FAILED: $reason"
  die "$reason"
}

promote() {
  local build_run_id=""
  local build_run_attempt=""
  local source_revision=""
  local release_id
  local response
  local candidate
  local candidate_revision
  local candidate_created
  local candidate_epoch
  local active_before
  local previous_before
  local evaluation_epoch

  while (($#)); do
    case "$1" in
      --build-run-id)
        [[ $# -ge 2 ]] || usage
        build_run_id="$2"
        shift 2
        ;;
      --build-run-attempt)
        [[ $# -ge 2 ]] || usage
        build_run_attempt="$2"
        shift 2
        ;;
      --source-revision)
        [[ $# -ge 2 ]] || usage
        source_revision="$2"
        shift 2
        ;;
      *)
        usage
        ;;
    esac
  done

  [[ "$build_run_id" =~ ^[1-9][0-9]*$ ]] || die "build run ID must be positive"
  [[ "$build_run_attempt" =~ ^[1-9][0-9]*$ ]] || die "build run attempt must be positive"
  [[ "$source_revision" =~ ^[0-9a-f]{40}$ ]] || die "source revision must be a 40-character lowercase SHA"
  release_id="${build_run_id}.${build_run_attempt}"
  evaluation_epoch="${AMI_CHANNEL_EVALUATION_EPOCH:-$(date -u +%s)}"
  [[ "$evaluation_epoch" =~ ^[0-9]+$ ]] || die "candidate evaluation time must be a Unix epoch"

  response="$(run_aws_until "$(deadline_epoch)" default ec2 describe-images \
    --region "$AWS_REGION" \
    --owners self \
    --page-size 100 \
    --filters \
      "Name=state,Values=available" \
      "Name=tag:ghr:managed,Values=runner-ami-release" \
      "Name=tag:ghr:release_id,Values=$release_id" \
      "Name=tag:ghr:architecture,Values=$ARCHITECTURE" \
      "Name=tag:ghr:validation_status,Values=passed" \
    --output json)" || die "candidate lookup failed"

  [[ "$(jq -r '.Images | length' <<<"$response")" == "1" ]] ||
    die "candidate lookup must return exactly one image"

  candidate="$(jq -r '.Images[0].ImageId // empty' <<<"$response")"
  candidate_revision="$(jq -r '[.Images[0].Tags[]? | select(.Key == "ghr:source_revision") | .Value] | if length == 1 then .[0] else "" end' <<<"$response")"
  candidate_created="$(jq -r '.Images[0].CreationDate // empty' <<<"$response")"

  [[ "$candidate" =~ ^ami-[0-9a-f]{17}$ ]] || die "candidate image ID is malformed"
  echo "::add-mask::$candidate"
  [[ "$(jq -r '.Images[0].Architecture // empty' <<<"$response")" == "$EC2_ARCHITECTURE" ]] ||
    die "candidate architecture does not match"
  [[ "$candidate_revision" == "$source_revision" ]] || die "candidate source revision does not match build attempt"
  candidate_epoch="$(date -u -d "$candidate_created" +%s 2>/dev/null)" ||
    die "candidate creation time is malformed"

  active_before="$(read_parameter "$ACTIVE_PARAMETER")" || die "active channel is unreadable"
  previous_before="$(read_parameter "$PREVIOUS_PARAMETER")" || die "previous channel is unreadable"
  echo "::add-mask::$active_before"
  echo "::add-mask::$previous_before"
  validate_channel_image "$active_before" || die "active channel does not reference a valid image"
  validate_channel_image "$previous_before" || die "previous channel does not reference a valid image"

  if [[ "$candidate" == "$active_before" ]]; then
    wait_for_launch_template "$candidate" || die "launch template did not resolve to the active candidate"
    return 0
  fi

  ((evaluation_epoch - candidate_epoch < MAX_CANDIDATE_AGE_SECONDS)) ||
    die "candidate is at least seven days old"

  protect_recovery_source "$previous_before" "$active_before" "$previous_before"

  if [[ "$previous_before" != "$active_before" ]]; then
    if ! write_parameter "$PREVIOUS_PARAMETER" "$active_before" "$previous_before"; then
      case "$WRITE_RESULT" in
        unchanged)
          die "previous channel write did not apply"
          ;;
        unknown | drift)
          die "COMPENSATION_FAILED: previous channel write result is unreadable"
          ;;
      esac
    fi
  fi

  if ! read_channels; then
    die "COMPENSATION_FAILED: channels are unreadable after previous write"
  fi
  if [[ "$CHANNEL_RECOVERY" != "$previous_before" ]]; then
    die "COMPENSATION_FAILED: recovery channel drifted after previous write"
  fi
  if [[ "$CHANNEL_ACTIVE" == "$candidate" && "$CHANNEL_PREVIOUS" == "$active_before" ]]; then
    if ! wait_for_channels \
      "$candidate" "$active_before" "$previous_before" \
      "$active_before" "$active_before" "$previous_before"; then
      case "$CHANNEL_WAIT_RESULT" in
        unchanged)
          fail_after_promotion_write \
            "promotion channels did not converge" \
            "$active_before" \
            "$previous_before" \
            "$candidate"
          ;;
        unknown | drift)
          die "COMPENSATION_FAILED: promotion channel state is unreadable or unexpected"
          ;;
      esac
    fi
    if wait_for_launch_template "$candidate"; then
      return 0
    fi
    fail_after_promotion_write \
      "promotion verification did not converge" \
      "$active_before" \
      "$previous_before" \
      "$candidate"
  fi
  if [[ "$CHANNEL_ACTIVE" != "$active_before" || "$CHANNEL_PREVIOUS" != "$active_before" ]]; then
    die "COMPENSATION_FAILED: unexpected channel tuple after previous write"
  fi

  if ! write_parameter "$ACTIVE_PARAMETER" "$candidate" "$active_before"; then
    case "$WRITE_RESULT" in
      unchanged)
        fail_after_promotion_write \
          "active channel write did not converge" \
          "$active_before" \
          "$previous_before" \
          "$candidate"
        ;;
      unknown | drift)
        die "COMPENSATION_FAILED: active channel write result is unreadable or unexpected"
        ;;
    esac
  fi

  if ! wait_for_channels \
    "$candidate" "$active_before" "$previous_before" \
    "$active_before" "$active_before" "$previous_before"; then
    case "$CHANNEL_WAIT_RESULT" in
      unchanged)
        fail_after_promotion_write \
          "promotion channels did not converge" \
          "$active_before" \
          "$previous_before" \
          "$candidate"
        ;;
      unknown | drift)
        die "COMPENSATION_FAILED: promotion channel state is unreadable or unexpected"
        ;;
    esac
  fi
  if ! wait_for_launch_template "$candidate"; then
    fail_after_promotion_write \
      "promotion verification did not converge" \
      "$active_before" \
      "$previous_before" \
      "$candidate"
  fi
}

rollback() {
  (($# == 0)) || usage

  local active_before
  local previous_before

  active_before="$(read_parameter "$ACTIVE_PARAMETER")" || die "active channel is unreadable"
  previous_before="$(read_parameter "$PREVIOUS_PARAMETER")" || die "previous channel is unreadable"
  echo "::add-mask::$active_before"
  echo "::add-mask::$previous_before"
  validate_channel_image "$active_before" || die "active channel does not reference a valid image"
  validate_channel_image "$previous_before" || die "previous channel does not reference a valid image"

  if [[ "$active_before" == "$previous_before" ]]; then
    wait_for_launch_template "$active_before" || die "launch template did not resolve to active"
    return 0
  fi

  protect_recovery_source "$active_before" "$active_before" "$previous_before"

  if ! write_parameter "$ACTIVE_PARAMETER" "$previous_before" "$active_before"; then
    case "$WRITE_RESULT" in
      unchanged)
        die "rollback active write did not apply"
        ;;
      unknown | drift)
        die "COMPENSATION_FAILED: rollback write result is unreadable or unexpected"
        ;;
    esac
  fi

  if ! wait_for_channels \
    "$previous_before" "$previous_before" "$active_before" \
    "$active_before" "$previous_before" "$active_before"; then
    case "$CHANNEL_WAIT_RESULT" in
      unchanged)
        die "rollback did not converge and active is already restored"
        ;;
      unknown | drift)
        die "COMPENSATION_FAILED: rollback channels are unreadable or unexpected"
        ;;
    esac
  fi
  if wait_for_launch_template "$previous_before"; then
    return 0
  fi

  read_channels ||
    die "COMPENSATION_FAILED: rollback channels are unreadable"
  if [[ "$CHANNEL_RECOVERY" != "$active_before" ]]; then
    die "COMPENSATION_FAILED: recovery channel drifted before rollback compensation"
  fi
  if [[ "$CHANNEL_ACTIVE" == "$active_before" &&
    "$CHANNEL_PREVIOUS" == "$previous_before" ]]; then
    die "rollback did not converge and active is already restored"
  fi
  if [[ "$CHANNEL_ACTIVE" != "$previous_before" || "$CHANNEL_PREVIOUS" != "$previous_before" ]]; then
    die "COMPENSATION_FAILED: external rollback channel drift"
  fi

  write_parameter "$ACTIVE_PARAMETER" "$active_before" "$previous_before" ||
    die "COMPENSATION_FAILED after rollback verification"
  if ! read_channels ||
    [[ "$CHANNEL_ACTIVE" != "$active_before" ]] ||
    [[ "$CHANNEL_PREVIOUS" != "$previous_before" ]] ||
    [[ "$CHANNEL_RECOVERY" != "$active_before" ]]; then
    die "COMPENSATION_FAILED: rollback original tuple was not restored"
  fi
  die "rollback launch template verification did not converge"
}

case "$command" in
  promote) promote "$@" ;;
  rollback) rollback "$@" ;;
  *) usage ;;
esac
