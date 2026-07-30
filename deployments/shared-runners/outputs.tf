output "webhook_endpoint" {
  description = "API Gateway webhook URL — configure this in your GitHub App settings"
  value       = module.runners.webhook.endpoint
}

output "webhook_secret" {
  description = "Webhook secret — configure this in your GitHub App settings"
  value       = random_id.webhook_secret.hex
  sensitive   = true
}

output "runners_label_arm64" {
  description = "GitHub Actions label set for arm64 self-hosted jobs"
  value       = "[\"self-hosted\", \"linux\", \"arm64\"]"
}

output "runners_label_amd64" {
  description = "GitHub Actions label set for amd64 self-hosted jobs"
  value       = "[\"self-hosted\", \"linux\", \"x64\"]"
}

output "ami_release_configuration" {
  description = "Values to configure as GitHub Actions repository secrets after apply"
  value = {
    build_role_arn                  = aws_iam_role.ami_build.arn
    promotion_role_arns             = { for architecture, role in aws_iam_role.ami_promotion : architecture => role.arn }
    builder_instance_profile_name   = aws_iam_instance_profile.ami_builder.name
    validator_instance_profile_name = aws_iam_instance_profile.ami_validator.name
    builder_security_group_id       = aws_security_group.ami_builder.id
    validator_security_group_id     = aws_security_group.ami_validator.id
    subnet_id                       = var.subnet_ids[0]
    active_parameter_arns           = { for architecture, parameter in aws_ssm_parameter.runner_ami_active : architecture => parameter.arn }
    previous_parameter_arns         = { for architecture, parameter in aws_ssm_parameter.runner_ami_previous : architecture => parameter.arn }
    recovery_parameter_arns         = { for architecture, parameter in aws_ssm_parameter.runner_ami_recovery : architecture => parameter.arn }
  }
}
