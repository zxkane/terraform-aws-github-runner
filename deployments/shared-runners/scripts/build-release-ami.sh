#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
readonly REPO_ROOT
# shellcheck disable=SC1091 # Resolved relative to this script at runtime.
source "$SCRIPT_DIR/ami-log-sanitizer.sh"

: "${ARCHITECTURE:?ARCHITECTURE must be amd64 or arm64}"
: "${AWS_REGION:?AWS_REGION must be set}"
: "${RELEASE_ID:?RELEASE_ID must be run_id.run_attempt}"
: "${SOURCE_REVISION:?SOURCE_REVISION must be a 40-character SHA}"
: "${AMI_BUILDER_INSTANCE_PROFILE:?AMI_BUILDER_INSTANCE_PROFILE must be set}"
: "${AMI_BUILDER_SECURITY_GROUP_ID:?AMI_BUILDER_SECURITY_GROUP_ID must be set}"
: "${AMI_SUBNET_ID:?AMI_SUBNET_ID must be set}"
: "${AMI_SOURCE_OWNER_ID:?AMI_SOURCE_OWNER_ID must be the trusted Canonical AWS account ID}"
: "${AMI_ID_OUTPUT_FILE:?AMI_ID_OUTPUT_FILE must be set}"

[[ "$RELEASE_ID" =~ ^[0-9]+\.[1-9][0-9]*$ ]] || {
  echo "Invalid RELEASE_ID" >&2
  exit 2
}
[[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Invalid SOURCE_REVISION" >&2
  exit 2
}
[[ "$AMI_SOURCE_OWNER_ID" =~ ^[0-9]{12}$ ]] || {
  echo "Invalid AMI_SOURCE_OWNER_ID" >&2
  exit 2
}

case "$ARCHITECTURE" in
  amd64) image_dir="$REPO_ROOT/images/ubuntu-resolute" ;;
  arm64) image_dir="$REPO_ROOT/images/ubuntu-resolute-arm64" ;;
  *)
    echo "Unsupported architecture" >&2
    exit 2
    ;;
esac

runner_version="$(
  curl --fail --silent --show-error --location --retry 3 \
    -H "Authorization: Bearer ${GITHUB_TOKEN:?GITHUB_TOKEN must be set}" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/actions/runner/releases/latest |
    jq -er '.tag_name | ltrimstr("v")'
)"

tmp_dir="$(mktemp -d)"
chmod 0700 "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT
build_log="$tmp_dir/packer.log"
export PKR_VAR_github_api_token="$GITHUB_TOKEN"

(
  cd "$image_dir"
  packer init .
  packer_args=(
    -var-file=shared.pkrvars.hcl \
    -var "region=$AWS_REGION" \
    -var "runner_version=$runner_version" \
    -var "release_id=$RELEASE_ID" \
    -var "source_revision=$SOURCE_REVISION" \
    -var "source_ami_owner=$AMI_SOURCE_OWNER_ID" \
    -var "iam_instance_profile=$AMI_BUILDER_INSTANCE_PROFILE" \
    -var "security_group_id=$AMI_BUILDER_SECURITY_GROUP_ID" \
    -var "subnet_id=$AMI_SUBNET_ID" \
  )
  packer validate "${packer_args[@]}" .
  packer build "${packer_args[@]}" .
) >"$build_log" 2>&1 || {
  sanitize_ami_build_log "$build_log" >&2
  exit 1
}

manifest="$image_dir/manifest.json"
ami_id="$(jq -er '.builds[-1].artifact_id | split(":")[-1]' "$manifest")"
[[ "$ami_id" =~ ^ami-[0-9a-f]{17}$ ]] || {
  echo "Packer manifest did not contain one AMI ID" >&2
  exit 1
}

echo "::add-mask::$ami_id"
sanitize_ami_build_log "$build_log"

printf '%s\n' "$ami_id" >"$AMI_ID_OUTPUT_FILE"
chmod 0600 "$AMI_ID_OUTPUT_FILE"
