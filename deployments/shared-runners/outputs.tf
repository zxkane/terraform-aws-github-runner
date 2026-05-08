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
