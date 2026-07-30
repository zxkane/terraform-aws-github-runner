packer {
  required_plugins {
    amazon = {
      version = ">= 0.0.2"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "runner_version" {
  description = "The version (no v prefix) of the runner software to install https://github.com/actions/runner/releases. The latest release will be fetched from GitHub if not provided."
  default     = null
}

variable "github_api_token" {
  description = "Optional GitHub token used by the runner release data source"
  type        = string
  default     = null
  sensitive   = true
}

variable "release_id" {
  description = "GitHub Actions run_id.run_attempt identity for an automated release"
  type        = string
  default     = null
}

variable "source_revision" {
  description = "Git commit SHA that produced an automated release"
  type        = string
  default     = null
}

variable "source_ami_owner" {
  description = "AWS account ID for the trusted Canonical source AMIs"
  type        = string

  validation {
    condition     = var.source_ami_owner == "self" || can(regex("^[0-9]{12}$", var.source_ami_owner))
    error_message = "Source_ami_owner must be a 12-digit AWS account ID or self for validation."
  }
}

variable "region" {
  description = "The region to build the image in"
  type        = string
  default     = "us-east-1"
}

variable "security_group_id" {
  description = "The ID of the security group Packer will associate with the builder to enable access"
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "If using VPC, the ID of the subnet, such as subnet-12345def, where Packer will launch the EC2 instance. This field is required if you are using an non-default VPC"
  type        = string
  default     = null
}

variable "instance_type" {
  description = "The instance type Packer will use for the builder"
  type        = string
  default     = "t4g.large"
}

variable "iam_instance_profile" {
  description = "IAM instance profile Packer will use for Session Manager connectivity"
  type        = string
  default     = "runner-ami-builder"
}

variable "root_volume_size_gb" {
  type    = number
  default = 30
}

variable "ebs_delete_on_termination" {
  description = "Indicates whether the EBS volume is deleted on instance termination."
  type        = bool
  default     = true
}

variable "global_tags" {
  description = "Tags to apply to everything"
  type        = map(string)
  default     = {}
}

variable "ami_tags" {
  description = "Tags to apply to the AMI"
  type        = map(string)
  default     = {}
}

variable "snapshot_tags" {
  description = "Tags to apply to the snapshot"
  type        = map(string)
  default     = {}
}

variable "custom_shell_commands" {
  description = "Additional commands to run on the EC2 instance, to customize the instance, like installing packages"
  type        = list(string)
  default     = []
}

data "http" github_runner_release_json {
  url = "https://api.github.com/repos/actions/runner/releases/latest"
  request_headers = merge(
    {
      Accept               = "application/vnd.github+json"
      X-GitHub-Api-Version = "2022-11-28"
    },
    var.github_api_token == null ? {} : {
      Authorization = "Bearer ${var.github_api_token}"
    },
  )
}

locals {
  runner_version = coalesce(var.runner_version, trimprefix(jsondecode(data.http.github_runner_release_json.body).tag_name, "v"))
  release_tags = var.release_id != null && var.source_revision != null ? {
    "ghr:managed"           = "runner-ami-release"
    "ghr:release_id"        = var.release_id
    "ghr:architecture"      = "arm64"
    "ghr:ami_role"          = "builder"
    "ghr:source_revision"   = var.source_revision
    "ghr:validation_status" = "candidate"
  } : {}
  ami_suffix = var.release_id != null ? var.release_id : formatdate("YYYYMMDDhhmm", timestamp())
}

source "amazon-ebs" "githubrunner" {
  ami_name                    = "github-runner-ubuntu-resolute-arm64-${local.ami_suffix}"
  communicator                = "ssh"
  instance_type               = var.instance_type
  iam_instance_profile        = var.iam_instance_profile
  region                      = var.region
  security_group_id           = var.security_group_id
  subnet_id                   = var.subnet_id
  associate_public_ip_address = false
  temporary_key_pair_name     = "github-runner-ami-arm64-${local.ami_suffix}"
  ssh_interface               = "session_manager"
  imds_support                = "v2.0"

  # Packer's builder instance must also speak IMDSv2 — AWS accounts with
  # httpTokensEnforced=true reject any launch that allows IMDSv1. `imds_support`
  # above only governs the IMDS mode registered on the resulting AMI, not the
  # builder instance itself.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  source_ami_filter {
    filters = {
      name                = "ubuntu-pro-server/images/hvm-ssd-gp3/ubuntu-resolute-26.04-arm64-pro-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = [var.source_ami_owner]
  }
  ssh_username = "ubuntu"
  tags = merge(
    var.global_tags,
    var.ami_tags,
    local.release_tags,
    {
      OS_Version    = "ubuntu-resolute-pro"
      Release       = "Latest"
      Base_AMI_Name = "{{ .SourceAMIName }}"
  })
  snapshot_tags = merge(
    var.global_tags,
    var.snapshot_tags,
    local.release_tags,
  )
  run_tags = merge(
    var.global_tags,
    local.release_tags,
    {
      "ghr:managed"  = "runner-ami-release"
      "ghr:ami_role" = "builder"
    },
  )
  run_volume_tags = merge(
    var.global_tags,
    local.release_tags,
    {
      "ghr:managed"  = "runner-ami-release"
      "ghr:ami_role" = "builder"
    },
  )

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = "${var.root_volume_size_gb}"
    volume_type           = "gp3"
    delete_on_termination = "${var.ebs_delete_on_termination}"
    encrypted             = true
  }
}

build {
  name = "githubactions-runner"
  sources = [
    "source.amazon-ebs.githubrunner"
  ]
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]
    inline = concat([
      # `cloud-init status --wait` is a readiness barrier, not a correctness
      # gate. It exits 2 when cloud-init finishes but hit *recoverable* errors
      # (degraded state) — common on a fresh 26.04 first boot. Under Packer's
      # per-line exit-0 requirement that aborted the whole build (observed:
      # "Script exited with non-zero exit status: 2"). Accept exit 2 (finished,
      # degraded) but still fail on exit 1 (cloud-init crashed). The subsequent
      # apt steps surface any real package problem on their own.
      "sudo cloud-init status --wait || [ $? -eq 2 ]",
      "sudo apt-get -y update",
      "sudo apt-get -y upgrade -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'",
      "sudo apt-get -y install ca-certificates curl gnupg lsb-release",
      "sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg",
      "echo deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",
      "sudo apt-get -y update",
      "sudo apt-get -y install docker-ce docker-ce-cli containerd.io jq git unzip build-essential",
      "sudo systemctl enable containerd.service",
      "sudo service docker start",
      "sudo usermod -a -G docker ubuntu",
      "sudo curl -f https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/arm64/latest/amazon-cloudwatch-agent.deb -o amazon-cloudwatch-agent.deb",
      "sudo dpkg -i amazon-cloudwatch-agent.deb",
      "sudo systemctl restart amazon-cloudwatch-agent",
      "sudo curl -f https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip -o awscliv2.zip",
      "unzip awscliv2.zip",
      "sudo ./aws/install",
    ], var.custom_shell_commands)
  }

  provisioner "file" {
    content = templatefile("../install-runner.sh", {
      install_runner = templatefile("../../modules/runners/templates/install-runner.sh", {
        ARM_PATCH                       = ""
        S3_LOCATION_RUNNER_DISTRIBUTION = ""
        RUNNER_ARCHITECTURE             = "arm64"
      })
    })
    destination = "/tmp/install-runner.sh"
  }

  provisioner "shell" {
    environment_vars = [
      "RUNNER_TARBALL_URL=https://github.com/actions/runner/releases/download/v${local.runner_version}/actions-runner-linux-arm64-${local.runner_version}.tar.gz"
    ]
    inline = [
      "sudo chmod +x /tmp/install-runner.sh",
      "echo ubuntu | tee -a /tmp/install-user.txt",
      "sudo RUNNER_ARCHITECTURE=arm64 RUNNER_TARBALL_URL=$RUNNER_TARBALL_URL /tmp/install-runner.sh",
      "echo ImageOS=ubuntu26 | tee -a /opt/actions-runner/.env"
    ]
  }

  provisioner "file" {
    source      = "../hooks/job-started.sh"
    destination = "/tmp/job-started.sh"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/actions-runner/hooks",
      "sudo mv /tmp/job-started.sh /opt/actions-runner/hooks/job-started.sh",
      "sudo chown ubuntu:ubuntu /opt/actions-runner/hooks/job-started.sh",
      "sudo chmod 0755 /opt/actions-runner/hooks/job-started.sh",
      "echo ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/actions-runner/hooks/job-started.sh | sudo tee -a /opt/actions-runner/.env",
    ]
  }

  provisioner "file" {
    content = templatefile("../start-runner.sh", {
      start_runner = templatefile("../../modules/runners/templates/start-runner.sh", { metadata_tags = "enabled" })
    })
    destination = "/tmp/start-runner.sh"
  }

  provisioner "file" {
    source      = "../is-ami-validation.sh"
    destination = "/tmp/is-ami-validation.sh"
  }

  provisioner "shell" {
    inline = [
      "sudo install -m 0755 /tmp/is-ami-validation.sh /opt/actions-runner/bin/is-ami-validation.sh",
      "sudo mv /tmp/start-runner.sh /var/lib/cloud/scripts/per-boot/start-runner.sh",
      "sudo chmod +x /var/lib/cloud/scripts/per-boot/start-runner.sh",
    ]
  }

  # Ship the AMI with an EMPTY apt index, not the index frozen at build time.
  # The build's `apt-get update` (and Docker repo add) leave /var/lib/apt/lists
  # populated; baked into the AMI, that index ages with the image and points at
  # package versions Ubuntu's archive rotates away after each point-release.
  # A consumer that runs `apt-get install <pkg>.deb` WITHOUT a preceding
  # `apt-get update` then resolves a dependency (e.g. libegl-mesa0) to the stale
  # cached version and 404s fetching it. Clearing the lists forces the runner's
  # first apt operation to pull a fresh index, so the AMI can never carry a
  # stale version pointer onto a runner. (Consumers should still `apt-get update`
  # before installing; this just guarantees we never bake the staleness in.)
  provisioner "shell" {
    inline = [
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
