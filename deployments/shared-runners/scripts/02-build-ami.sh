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
case "$ARCH" in
  arm64) IMAGE_DIR="$REPO_ROOT/images/ubuntu-noble-arm64" ;;
  amd64) IMAGE_DIR="$REPO_ROOT/images/ubuntu-noble" ;;
  *) echo "Unknown ARCH=$ARCH (expected arm64 or amd64)" >&2; exit 1 ;;
esac

echo "Building shared GitHub Runner AMI ($ARCH / Ubuntu 24.04 Pro)..."
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
packer validate -var-file=shared.pkrvars.hcl -var "runner_version=$RUNNER_VERSION" .
packer build -var-file=shared.pkrvars.hcl -var "runner_version=$RUNNER_VERSION" .

echo ""
echo "AMI built successfully!"
echo "Check manifest.json for the AMI ID:"
cat manifest.json | jq '.builds[-1].artifact_id'
