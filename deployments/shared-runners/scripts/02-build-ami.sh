#!/bin/bash
# Build the shared GitHub Actions runner AMI for arm64 or amd64.
#
# Usage:
#   ARCH=arm64 ./scripts/02-build-ami.sh   # default
#   ARCH=amd64 ./scripts/02-build-ami.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ARCH="${ARCH:-arm64}"
: "${AMI_BUILDER_INSTANCE_PROFILE:?Set AMI_BUILDER_INSTANCE_PROFILE from terraform output ami_release_configuration}"
: "${AMI_BUILDER_SECURITY_GROUP_ID:?Set AMI_BUILDER_SECURITY_GROUP_ID from terraform output ami_release_configuration}"
: "${AMI_SUBNET_ID:?Set AMI_SUBNET_ID from terraform output ami_release_configuration}"
: "${AMI_SOURCE_OWNER_ID:?Set AMI_SOURCE_OWNER_ID to the published Canonical AWS account ID}"
[[ "$AMI_SOURCE_OWNER_ID" =~ ^[0-9]{12}$ ]] || {
  echo "AMI_SOURCE_OWNER_ID must be a 12-digit AWS account ID" >&2
  exit 2
}

case "$ARCH" in
  arm64) IMAGE_DIR="$REPO_ROOT/images/ubuntu-resolute-arm64" ;;
  amd64) IMAGE_DIR="$REPO_ROOT/images/ubuntu-resolute" ;;
  *) echo "Unknown ARCH=$ARCH (expected arm64 or amd64)" >&2; exit 1 ;;
esac

echo "Building shared GitHub Runner AMI ($ARCH / Ubuntu 26.04 Pro)..."
echo "  Image dir: $IMAGE_DIR"
echo "  Region: us-east-1"

cd "$IMAGE_DIR"

# Pin runner_version explicitly. The Packer template defaults to fetching
# `latest` via data.http at apply time, but Packer's validate step trips over
# the unresolved value in some versions; pinning here avoids that and also
# makes the build reproducible.
RUNNER_VERSION="${RUNNER_VERSION:-$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['tag_name'].lstrip('v'))")}"
echo "  Runner version: $RUNNER_VERSION"

packer init .
packer_args=(
  -var-file=shared.pkrvars.hcl \
  -var "runner_version=$RUNNER_VERSION" \
  -var "source_ami_owner=$AMI_SOURCE_OWNER_ID" \
  -var "iam_instance_profile=$AMI_BUILDER_INSTANCE_PROFILE" \
  -var "security_group_id=$AMI_BUILDER_SECURITY_GROUP_ID" \
  -var "subnet_id=$AMI_SUBNET_ID" \
)
packer validate "${packer_args[@]}" .
packer build "${packer_args[@]}" .

echo ""
echo "AMI built successfully!"
echo "Check manifest.json for the AMI ID:"
jq '.builds[-1].artifact_id' manifest.json
