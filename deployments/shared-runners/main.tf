locals {
  environment = "gh-runner"
  aws_region  = "us-east-1"

  # Tags applied to every runner EC2 instance. Intentionally project-agnostic —
  # this fleet is shared across multiple projects, and per-project usage is tracked
  # via CloudWatch Logs Insights against the webhook lambda log (see CLAUDE.md
  # "按项目追踪 runner 用量"), not EC2 tags. A single runner instance handles jobs
  # from many repos in its lifetime, so a Project tag here would be misleading.
  runner_ec2_tags = {
    ManagedBy   = "github-actions-runner"
    SharedInfra = "true"
  }

  # 60 GB encrypted gp3 root volume — shared by both fleets.
  block_device_mappings = [{
    device_name = "/dev/sda1"
    volume_size = 60
    volume_type = "gp3"
    encrypted   = true
  }]

  # Common runner config shared by both fleets. Per-fleet overrides applied below.
  common_runner_config = {
    runner_os                       = "linux"
    runner_run_as                   = "ubuntu"
    enable_userdata                 = false
    enable_runner_binaries_syncer   = false
    enable_organization_runners     = false
    enable_ephemeral_runners        = false
    enable_ssm_on_runners           = true
    create_service_linked_role_spot = true
    delay_webhook_event             = 30
    enable_job_queued_check         = false
    minimum_running_time_in_minutes = 15
    scale_down_schedule_expression  = "cron(* * * * ? *)"
    instance_target_capacity_type   = "spot"
    instance_allocation_strategy    = "price-capacity-optimized"
    block_device_mappings           = local.block_device_mappings
    runner_ec2_tags                 = local.runner_ec2_tags
    job_retry = {
      enable           = true
      max_attempts     = 1
      delay_in_seconds = 180
    }
  }
}

resource "random_id" "webhook_secret" {
  byte_length = 20
}

data "aws_caller_identity" "current" {}

# ─── Multi-architecture GitHub Actions Runners ───
# arm64 fleet  → c8g (Graviton4)         — general CI workloads
# amd64 fleet  → c7a / c7i / m7a         — GPU container image builds (no GPU on the runner itself)
#
# Jobs route by GitHub label (`arm64` vs `x64`). exactMatch=true on each matcher
# prevents cross-routing between fleets.
module "runners" {
  source = "../../modules/multi-runner"

  aws_region = local.aws_region
  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids
  prefix     = local.environment
  tags = {
    Project = "SharedInfra"
  }

  github_app = {
    key_base64     = var.github_app_key_base64
    id             = var.github_app_id
    webhook_secret = random_id.webhook_secret.hex
  }

  # Enable the few fleet-level CloudWatch metrics the upstream lambdas emit:
  #   GitHubAppRateLimitRemaining (dimensions: AppId)
  #   RetryJob                    (dimensions: Environment, RetryCount)
  #   SpotInterruption*           (only when instance_termination_watcher is on)
  # None of these carry a repository dimension. For per-repo usage, query the
  # webhook lambda log via CloudWatch Logs Insights — see CLAUDE.md.
  metrics = {
    enable = true
    metric = {
      enable_github_app_rate_limit    = true
      enable_job_retry                = true
      enable_spot_termination_warning = true
    }
  }

  multi_runner_config = {
    "linux-arm64" = {
      matcherConfig = {
        labelMatchers = [["self-hosted", "linux", "arm64"]]
        exactMatch    = true
      }
      runner_config = merge(local.common_runner_config, {
        runner_architecture   = "arm64"
        runner_extra_labels   = ["linux", "arm64"]
        instance_types        = ["c8g.2xlarge"]
        runners_maximum_count = 10
        ami = {
          filter = { name = ["github-runner-ubuntu-noble-arm64-*"], state = ["available"] }
          owners = [data.aws_caller_identity.current.account_id]
        }
      })
    }

    "linux-amd64" = {
      matcherConfig = {
        labelMatchers = [["self-hosted", "linux", "x64"]]
        exactMatch    = true
      }
      runner_config = merge(local.common_runner_config, {
        runner_architecture = "x64"
        runner_extra_labels = ["linux", "x64"]
        # c7a (AMD EPYC) preferred for cost; c7i / m7a serve as spot-capacity fallbacks.
        instance_types        = ["c7a.4xlarge", "c7i.4xlarge", "m7a.4xlarge"]
        runners_maximum_count = 5
        ami = {
          filter = { name = ["github-runner-ubuntu-noble-amd64-*"], state = ["available"] }
          owners = [data.aws_caller_identity.current.account_id]
        }
      })
    }
  }
}

# ─── Configure GitHub App Webhook ───
module "webhook_github_app" {
  source     = "../../modules/webhook-github-app"
  depends_on = [module.runners]

  github_app = {
    key_base64     = var.github_app_key_base64
    id             = var.github_app_id
    webhook_secret = random_id.webhook_secret.hex
  }
  webhook_endpoint = module.runners.webhook.endpoint
}
