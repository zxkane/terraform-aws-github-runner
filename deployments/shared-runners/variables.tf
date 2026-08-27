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

variable "ami_release_github_repository" {
  description = "GitHub owner/repository allowed to assume the AMI release OIDC roles"
  type        = string
  default     = "zxkane/terraform-aws-github-runner"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.ami_release_github_repository))
    error_message = "ami_release_github_repository must use owner/repository format."
  }
}

variable "ami_release_default_branch" {
  description = "Default branch allowed to build runner AMIs"
  type        = string
  default     = "feat/multi-runners"
}

# Deletion is enabled by default on purpose. The default has to carry the
# decision, not a -var on the command line: scripts/03-deploy.sh does not pass
# this variable, so a `true` default would silently return the housekeeper to
# dry-run on the next routine deploy. Set it to `true` here to pause cleanup.
variable "ami_housekeeper_dry_run" {
  description = "Report release AMIs older than seven days instead of deleting them"
  type        = bool
  default     = false
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
