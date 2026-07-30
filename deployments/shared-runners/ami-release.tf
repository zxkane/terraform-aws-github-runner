locals {
  ami_architectures = toset(["amd64", "arm64"])

  ami_channel_names = {
    amd64 = {
      active   = "/github-action-runners/gh-runner/linux-amd64/runners/config/ami_id"
      previous = "/github-action-runners/gh-runner/linux-amd64/runners/config/ami_previous_id"
      recovery = "/github-action-runners/gh-runner/linux-amd64/runners/config/ami_recovery_id"
    }
    arm64 = {
      active   = "/github-action-runners/gh-runner/linux-arm64/runners/config/ami_id"
      previous = "/github-action-runners/gh-runner/linux-arm64/runners/config/ami_previous_id"
      recovery = "/github-action-runners/gh-runner/linux-arm64/runners/config/ami_recovery_id"
    }
  }

  ami_launch_template_names = {
    amd64 = "gh-runner-linux-amd64-action-runner"
    arm64 = "gh-runner-linux-arm64-action-runner"
  }

  ami_promotion_role_names = {
    amd64 = "runner-ami-promotion-amd64"
    arm64 = "runner-ami-promotion-arm64"
  }
}

data "aws_partition" "current" {}

data "aws_iam_openid_connect_provider" "github_actions" {
  arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_ssm_parameter" "runner_ami_active_before_migration" {
  for_each = local.ami_architectures
  name     = local.ami_channel_names[each.key].active
}

resource "aws_ssm_parameter" "runner_ami_active" {
  for_each = local.ami_architectures

  name      = local.ami_channel_names[each.key].active
  type      = "String"
  data_type = "aws:ec2:image"
  value     = data.aws_ssm_parameter.runner_ami_active_before_migration[each.key].value

  tags = {
    "ghr:ami_architecture" = each.key
    "ghr:ami_channel"      = "active"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [value]
  }
}

resource "aws_ssm_parameter" "runner_ami_previous" {
  for_each = local.ami_architectures

  name      = local.ami_channel_names[each.key].previous
  type      = "String"
  data_type = "aws:ec2:image"
  value     = data.aws_ssm_parameter.runner_ami_active_before_migration[each.key].value

  tags = {
    "ghr:ami_architecture" = each.key
    "ghr:ami_channel"      = "previous"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [value]
  }
}

resource "aws_ssm_parameter" "runner_ami_recovery" {
  for_each = local.ami_architectures

  name      = local.ami_channel_names[each.key].recovery
  type      = "String"
  data_type = "aws:ec2:image"
  value     = data.aws_ssm_parameter.runner_ami_active_before_migration[each.key].value

  tags = {
    "ghr:ami_architecture" = each.key
    "ghr:ami_channel"      = "recovery"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [value]
  }
}

moved {
  from = module.runners.module.runners["linux-amd64"].aws_ssm_parameter.runner_ami_id[0]
  to   = aws_ssm_parameter.runner_ami_active["amd64"]
}

moved {
  from = module.runners.module.runners["linux-arm64"].aws_ssm_parameter.runner_ami_id[0]
  to   = aws_ssm_parameter.runner_ami_active["arm64"]
}

data "aws_iam_policy_document" "ami_build_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.ami_release_github_repository}:ref:refs/heads/${var.ami_release_default_branch}"]
    }
  }
}

resource "aws_iam_role" "ami_build" {
  name               = "runner-ami-build"
  path               = "/${local.environment}/"
  assume_role_policy = data.aws_iam_policy_document.ami_build_assume_role.json
}

data "aws_iam_policy_document" "ami_build" {
  statement {
    sid = "ReadEc2BuildState"
    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImageAttribute",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceAttribute",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSnapshots",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVpcs",
      "ec2:DescribeVolumes",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "UseApprovedLaunchInputs"
    actions = ["ec2:RunInstances"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1::image/*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1::snapshot/*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:network-interface/*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:subnet/${var.subnet_ids[0]}",
      aws_security_group.ami_builder.arn,
      aws_security_group.ami_validator.arn,
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:key-pair/github-runner-ami-amd64-*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:key-pair/github-runner-ami-arm64-*",
    ]
  }

  statement {
    sid     = "LaunchTaggedAmiInstances"
    actions = ["ec2:RunInstances"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:instance/*",
    ]

    condition {
      test     = "ArnEquals"
      variable = "ec2:InstanceProfile"
      values = [
        aws_iam_instance_profile.ami_builder.arn,
        aws_iam_instance_profile.ami_validator.arn,
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:InstanceType"
      values   = ["t3.large", "t4g.large"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/ghr:managed"
      values   = ["runner-ami-release"]
    }
  }

  statement {
    sid       = "LaunchTaggedEncryptedVolumes"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:volume/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/ghr:managed"
      values   = ["runner-ami-release"]
    }

    condition {
      test     = "Bool"
      variable = "ec2:Encrypted"
      values   = ["true"]
    }
  }

  statement {
    sid       = "CreateImagesFromManagedBuilders"
    actions   = ["ec2:CreateImage"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/ghr:ami_role"
      values   = ["builder"]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/ghr:managed"
      values   = ["runner-ami-release"]
    }
  }

  statement {
    sid     = "CreateTaggedReleaseImageResources"
    actions = ["ec2:CreateImage"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1::image/*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1::snapshot/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/ghr:managed"
      values   = ["runner-ami-release"]
    }
  }

  statement {
    sid     = "TagAmiBuildResourcesOnCreate"
    actions = ["ec2:CreateTags"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1::image/*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1::snapshot/*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:instance/*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:key-pair/github-runner-ami-amd64-*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:key-pair/github-runner-ami-arm64-*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:network-interface/*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:volume/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateImage", "CreateKeyPair", "RunInstances"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/ghr:managed"
      values   = ["runner-ami-release"]
    }
  }

  statement {
    sid       = "SetManagedReleaseImageAttributes"
    actions   = ["ec2:ModifyImageAttribute"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:us-east-1::image/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/ghr:managed"
      values   = ["runner-ami-release"]
    }
  }

  statement {
    sid = "UpdateManagedAmiResourceTags"
    actions = [
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1::image/*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1::snapshot/*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:instance/*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:volume/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/ghr:managed"
      values   = ["runner-ami-release"]
    }
  }

  statement {
    sid = "ManageAmiBuildKeyPairs"
    actions = [
      "ec2:CreateKeyPair",
      "ec2:DeleteKeyPair",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:key-pair/github-runner-ami-amd64-*",
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:key-pair/github-runner-ami-arm64-*",
    ]
  }

  statement {
    sid = "ManageTaggedAmiInstances"
    actions = [
      "ec2:StopInstances",
      "ec2:TerminateInstances",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:instance/*",
    ]

    condition {
      test     = "ArnEquals"
      variable = "ec2:InstanceProfile"
      values = [
        aws_iam_instance_profile.ami_builder.arn,
        aws_iam_instance_profile.ami_validator.arn,
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/ghr:managed"
      values   = ["runner-ami-release"]
    }
  }

  statement {
    sid = "ReadSessionManagerState"
    actions = [
      "ssm:DescribeInstanceInformation",
      "ssm:DescribeSessions",
      "ssm:GetConnectionStatus",
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "StartTaggedBuilderSessions"
    actions   = ["ssm:StartSession"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/ghr:managed"
      values   = ["runner-ami-release"]
    }

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/ghr:ami_role"
      values   = ["builder"]
    }
  }

  statement {
    sid     = "UseBuilderSessionDocuments"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:us-east-1::document/AWS-StartPortForwardingSession",
    ]
  }

  statement {
    sid       = "ValidateTaggedInstances"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/ghr:managed"
      values   = ["runner-ami-release"]
    }
  }

  statement {
    sid       = "UseValidationDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:us-east-1::document/AWS-RunShellScript"]
  }

  statement {
    sid = "ManageOwnSessions"
    actions = [
      "ssm:ResumeSession",
      "ssm:TerminateSession",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:session/$${aws:userid}-*",
    ]
  }

  statement {
    sid       = "OpenOwnSessionDataChannels"
    actions   = ["ssmmessages:OpenDataChannel"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:session/$${aws:userid}-*"]
  }

  statement {
    sid       = "ReadInstanceProfiles"
    actions   = ["iam:GetInstanceProfile"]
    resources = [aws_iam_instance_profile.ami_builder.arn, aws_iam_instance_profile.ami_validator.arn]
  }

  statement {
    sid       = "PassAmiInstanceRoles"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ami_builder.arn, aws_iam_role.ami_validator.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ami_build" {
  name   = "runner-ami-build"
  role   = aws_iam_role.ami_build.id
  policy = data.aws_iam_policy_document.ami_build.json
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ami_builder" {
  name               = "runner-ami-builder"
  path               = "/${local.environment}/"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role" "ami_validator" {
  name               = "runner-ami-validator"
  path               = "/${local.environment}/"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "ami_managed_node" {
  statement {
    sid = "ManagedNodeMessaging"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ami_builder_managed_node" {
  name   = "runner-ami-managed-node"
  role   = aws_iam_role.ami_builder.id
  policy = data.aws_iam_policy_document.ami_managed_node.json
}

resource "aws_iam_role_policy" "ami_validator_managed_node" {
  name   = "runner-ami-managed-node"
  role   = aws_iam_role.ami_validator.id
  policy = data.aws_iam_policy_document.ami_managed_node.json
}

resource "aws_iam_instance_profile" "ami_builder" {
  name = "runner-ami-builder"
  path = "/${local.environment}/"
  role = aws_iam_role.ami_builder.name
}

resource "aws_iam_instance_profile" "ami_validator" {
  name = "runner-ami-validator"
  path = "/${local.environment}/"
  role = aws_iam_role.ami_validator.name
}

resource "aws_security_group" "ami_builder" {
  name_prefix            = "${local.environment}-ami-builder-"
  description            = "No-ingress security group for runner AMI builders"
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true
}

resource "aws_security_group" "ami_validator" {
  name_prefix            = "${local.environment}-ami-validator-"
  description            = "No-ingress security group for runner AMI validators"
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true
}

resource "aws_vpc_security_group_egress_rule" "ami_builder_ipv4" {
  security_group_id = aws_security_group.ami_builder.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "ami_validator_ipv4" {
  security_group_id = aws_security_group.ami_validator.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

data "aws_iam_policy_document" "ami_promotion_assume_role" {
  for_each = local.ami_architectures

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.ami_release_github_repository}:environment:runner-ami-production-${each.key}"]
    }
  }
}

resource "aws_iam_role" "ami_promotion" {
  for_each = local.ami_architectures

  name               = local.ami_promotion_role_names[each.key]
  path               = "/${local.environment}/"
  assume_role_policy = data.aws_iam_policy_document.ami_promotion_assume_role[each.key].json
}

data "aws_iam_policy_document" "ami_promotion" {
  for_each = local.ami_architectures

  statement {
    sid = "ValidateImagesAndLaunchTemplate"
    actions = [
      "ec2:DescribeImages",
      "ec2:DescribeLaunchTemplateVersions",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ReadAndWriteArchitectureChannels"
    actions = [
      "ssm:GetParameter",
      "ssm:PutParameter",
    ]
    resources = [
      aws_ssm_parameter.runner_ami_active[each.key].arn,
      aws_ssm_parameter.runner_ami_previous[each.key].arn,
      aws_ssm_parameter.runner_ami_recovery[each.key].arn,
    ]
  }
}

resource "aws_iam_role_policy" "ami_promotion" {
  for_each = local.ami_architectures

  name   = local.ami_promotion_role_names[each.key]
  role   = aws_iam_role.ami_promotion[each.key].id
  policy = data.aws_iam_policy_document.ami_promotion[each.key].json
}

data "aws_iam_policy_document" "release_ami_housekeeper" {
  statement {
    sid = "DiscoverProtectedAndManagedImages"
    actions = [
      "ec2:DescribeImages",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "ReadAmiChannels"
    actions = ["ssm:GetParameters"]
    resources = concat(
      [for parameter in aws_ssm_parameter.runner_ami_active : parameter.arn],
      [for parameter in aws_ssm_parameter.runner_ami_previous : parameter.arn],
      [for parameter in aws_ssm_parameter.runner_ami_recovery : parameter.arn],
    )
  }

  statement {
    sid       = "DeregisterManagedReleaseImages"
    actions   = ["ec2:DeregisterImage"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:us-east-1::image/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/ghr:managed"
      values   = ["runner-ami-release"]
    }
  }

  statement {
    sid       = "DeleteManagedReleaseSnapshots"
    actions   = ["ec2:DeleteSnapshot"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:us-east-1::snapshot/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/ghr:managed"
      values   = ["runner-ami-release"]
    }
  }
}

module "release_ami_housekeeper" {
  source = "../../modules/ami-housekeeper"

  prefix                 = local.environment
  lambda_zip             = "${path.root}/../../lambdas/functions/ami-housekeeper/ami-housekeeper.zip"
  lambda_runtime         = "nodejs24.x"
  lambda_architecture    = "arm64"
  lambda_timeout         = 900
  lambda_ami_policy_json = data.aws_iam_policy_document.release_ami_housekeeper.json

  lambda_schedule_expression = "cron(37 8 ? * MON *)"
  cleanup_config = {
    amiFilters = [
      {
        Name   = "state"
        Values = ["available"]
      },
      {
        Name   = "tag:ghr:managed"
        Values = ["runner-ami-release"]
      },
      {
        Name = "name"
        Values = [
          "github-runner-ubuntu-resolute-amd64-*",
          "github-runner-ubuntu-resolute-arm64-*",
        ]
      },
    ]
    dryRun              = var.ami_housekeeper_dry_run
    launchTemplateNames = values(local.ami_launch_template_names)
    minimumDaysOld      = 7
    ssmParameterNames = flatten([
      for architecture in local.ami_architectures : [
        local.ami_channel_names[architecture].active,
        local.ami_channel_names[architecture].previous,
        local.ami_channel_names[architecture].recovery,
      ]
    ])
  }

  tags = {
    Project   = "SharedInfra"
    Component = "runner-ami-release"
  }
}
