terraform {
  # Configure via: terraform init -backend-config="bucket=<your-bucket>" -backend-config="dynamodb_table=<your-table>"
  backend "s3" {
    key     = "github-runner/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }

  required_version = ">= 1.5"
}
