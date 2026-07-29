<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.21.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.21.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_runners"></a> [runners](#module\_runners) | ../../modules/multi-runner | n/a |
| <a name="module_webhook_github_app"></a> [webhook\_github\_app](#module\_webhook\_github\_app) | ../../modules/webhook-github-app | n/a |

## Resources

| Name | Type |
|------|------|
| [random_id.webhook_secret](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_github_app_id"></a> [github\_app\_id](#input\_github\_app\_id) | GitHub App ID (from App settings page) | `string` | n/a | yes |
| <a name="input_github_app_key_base64"></a> [github\_app\_key\_base64](#input\_github\_app\_key\_base64) | GitHub App private key, base64 encoded. Generate via: base64 -w 0 < app.pem | `string` | n/a | yes |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | List of private subnet IDs for runners (need NAT Gateway for outbound internet) | `list(string)` | n/a | yes |
| <a name="input_tf_state_bucket"></a> [tf\_state\_bucket](#input\_tf\_state\_bucket) | S3 bucket name for Terraform state | `string` | `"my-terraform-state"` | no |
| <a name="input_tf_state_lock_table"></a> [tf\_state\_lock\_table](#input\_tf\_state\_lock\_table) | DynamoDB table name for Terraform state locking | `string` | `"my-terraform-locks"` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC ID where runners will be launched | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_runners_label_amd64"></a> [runners\_label\_amd64](#output\_runners\_label\_amd64) | GitHub Actions label set for amd64 self-hosted jobs |
| <a name="output_runners_label_arm64"></a> [runners\_label\_arm64](#output\_runners\_label\_arm64) | GitHub Actions label set for arm64 self-hosted jobs |
| <a name="output_webhook_endpoint"></a> [webhook\_endpoint](#output\_webhook\_endpoint) | API Gateway webhook URL — configure this in your GitHub App settings |
| <a name="output_webhook_secret"></a> [webhook\_secret](#output\_webhook\_secret) | Webhook secret — configure this in your GitHub App settings |
<!-- END_TF_DOCS -->