#!/bin/bash
# Deploy the GitHub Runner infrastructure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${GITHUB_APP_ID:?Set GITHUB_APP_ID env var}"
: "${GITHUB_APP_KEY_BASE64:?Set GITHUB_APP_KEY_BASE64 env var (base64 -w 0 < app.pem)}"
: "${VPC_ID:?Set VPC_ID env var}"
: "${SUBNET_IDS:?Set SUBNET_IDS env var as JSON array, e.g. '[\"subnet-xxx\",\"subnet-yyy\"]'}"
: "${TF_STATE_BUCKET:?Set TF_STATE_BUCKET env var}"

cd "$DEPLOY_DIR"

# State backend uses S3 only — no DynamoDB locking. See CLAUDE.md
# "State Locking 现状" for why and the upgrade path.
echo "Initializing Terraform..."
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET"

echo "Planning deployment..."
terraform plan \
  -var "github_app_id=$GITHUB_APP_ID" \
  -var "github_app_key_base64=$GITHUB_APP_KEY_BASE64" \
  -var "vpc_id=$VPC_ID" \
  -var "subnet_ids=$SUBNET_IDS" \
  -out=tfplan

echo ""
read -p "Apply this plan? (y/N) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
  terraform apply tfplan

  echo ""
  echo "=== Deployment Complete ==="
  echo ""
  echo "Webhook URL (configure in GitHub App settings):"
  terraform output webhook_endpoint
  echo ""
  echo "Webhook Secret (configure in GitHub App settings):"
  terraform output -raw webhook_secret
  echo ""
  echo ""
  echo "Runner label for CI workflow:"
  terraform output runners_label
else
  echo "Cancelled."
fi
