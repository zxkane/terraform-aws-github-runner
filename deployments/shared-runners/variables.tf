variable "github_app_id" {
  description = "GitHub App ID (from App settings page)"
  type        = string
}

variable "github_app_key_base64" {
  description = "GitHub App private key, base64 encoded. Generate via: base64 -w 0 < app.pem"
  type        = string
  sensitive   = true
}

variable "vpc_id" {
  description = "VPC ID where runners will be launched"
  type        = string
}

variable "subnet_ids" {
  description = "List of private subnet IDs for runners (need NAT Gateway for outbound internet)"
  type        = list(string)
}

variable "tf_state_bucket" {
  description = "S3 bucket name for Terraform state"
  type        = string
  default     = "my-terraform-state"
}

variable "tf_state_lock_table" {
  description = "DynamoDB table name for Terraform state locking"
  type        = string
  default     = "my-terraform-locks"
}
