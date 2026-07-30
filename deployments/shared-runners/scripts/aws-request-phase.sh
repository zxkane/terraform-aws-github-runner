#!/usr/bin/env bash

monotonic_ms() {
  awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime
}

run_aws_until() {
  local request_deadline="$1"
  local max_attempts="$2"
  shift 2

  local remaining_ms=$((request_deadline - $(monotonic_ms)))
  ((remaining_ms > 0)) || return 124

  local cli_timeout=$(((remaining_ms + 999) / 1000))
  ((cli_timeout <= AWS_CLI_TIMEOUT_SECONDS)) || cli_timeout="$AWS_CLI_TIMEOUT_SECONDS"
  local request_ms="$remaining_ms"
  ((request_ms <= AWS_CLI_TIMEOUT_SECONDS * 1000)) ||
    request_ms=$((AWS_CLI_TIMEOUT_SECONDS * 1000))
  local request_seconds
  request_seconds="$(awk -v ms="$request_ms" 'BEGIN { printf "%.3f", ms / 1000 }')"

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
