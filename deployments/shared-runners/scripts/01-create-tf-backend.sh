#!/bin/bash
# Create S3 bucket and DynamoDB table for Terraform state
set -euo pipefail

REGION="us-east-1"
BUCKET="${TF_STATE_BUCKET:?Set TF_STATE_BUCKET env var}"
# DynamoDB lock table is optional. The default deployment uses pure S3 with
# no concurrency protection (see CLAUDE.md "State Locking 现状"). Set
# TF_STATE_LOCK_TABLE only if you actually want DynamoDB-based locking.
TABLE="${TF_STATE_LOCK_TABLE:-}"

echo "Creating S3 bucket for Terraform state..."
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" 2>/dev/null || echo "Bucket already exists"

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration '{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }'

if [ -n "$TABLE" ]; then
  echo "Creating DynamoDB table for state locking..."
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" 2>/dev/null || echo "Table already exists"
fi

echo "Terraform backend ready!"
echo "  S3 Bucket: $BUCKET"
if [ -n "$TABLE" ]; then
  echo "  DynamoDB Table: $TABLE"
  echo ""
  echo "Initialize with:"
  echo "  terraform init -backend-config=\"bucket=$BUCKET\" -backend-config=\"dynamodb_table=$TABLE\""
else
  echo "  DynamoDB locking: disabled (pure S3 backend)"
  echo ""
  echo "Initialize with:"
  echo "  terraform init -backend-config=\"bucket=$BUCKET\""
fi
