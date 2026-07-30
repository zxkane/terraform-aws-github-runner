#!/usr/bin/env bash

sanitize_ami_build_log() {
  local log_file="$1"
  sed -E \
    -e 's/ami-[0-9a-f]{8,17}/<masked-ami>/g' \
    -e 's/i-[0-9a-f]{8,17}/<masked-instance>/g' \
    -e 's/(subnet|sg|vpc|snap|vol|eni)-[0-9a-f]{8,17}/<masked-resource>/g' \
    -e 's/[0-9]{12}/<masked-account>/g' \
    "$log_file"
}
