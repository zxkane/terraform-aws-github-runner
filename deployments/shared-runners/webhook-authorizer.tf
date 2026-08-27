# ─── Webhook route authorizer ───
#
# The API Gateway authorization control requires an authorizer on the
# internet-facing webhook route. A Lambda authorizer cannot verify the GitHub
# HMAC: no authorizer payload format carries the request body, and the signature
# covers that body. The signature check therefore stays in the webhook lambda
# (`verifySignature`, lambdas/functions/webhook/src/webhook/index.ts) and this
# authorizer always allows.
#
# Attachment happens out of band in scripts/webhook-authorizer.sh rather than on
# the route resource, because the upstream webhook module ignores the route's
# authorizer attributes on purpose — a Terraform-managed attachment would form a
# dependency cycle, since the authorizer needs the API id and the route needs the
# authorizer id. See AGENTS.md "Webhook 网关授权" for the rollback path.

locals {
  webhook_authorizer_name = "${local.environment}-webhook-authorizer"
  webhook_authorizer_zip  = "${path.module}/../../lambdas/functions/webhook/webhook.zip"
  webhook_route_key       = "POST /webhook"
}

data "aws_iam_policy_document" "webhook_authorizer_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "webhook_authorizer" {
  name               = "${local.environment}-webhook-authorizer-lambda"
  path               = "/${local.environment}/"
  assume_role_policy = data.aws_iam_policy_document.webhook_authorizer_assume_role.json
}

resource "aws_cloudwatch_log_group" "webhook_authorizer" {
  name              = "/aws/lambda/${local.webhook_authorizer_name}"
  retention_in_days = 180
}

# CloudWatch Logs only. The authorizer reads no parameter, calls no API and
# reaches no queue, so it needs no other grant.
data "aws_iam_policy_document" "webhook_authorizer_logging" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.webhook_authorizer.arn}:*"]
  }
}

resource "aws_iam_role_policy" "webhook_authorizer_logging" {
  name   = "logging-policy"
  role   = aws_iam_role.webhook_authorizer.name
  policy = data.aws_iam_policy_document.webhook_authorizer_logging.json
}

# Reuses the webhook lambda artifact, which scripts/03-deploy.sh already builds,
# and selects the authorizer handler out of the same bundle.
resource "aws_lambda_function" "webhook_authorizer" {
  function_name    = local.webhook_authorizer_name
  description      = "Always-allow authorizer for the GitHub webhook route; HMAC verification stays in the webhook lambda"
  role             = aws_iam_role.webhook_authorizer.arn
  filename         = local.webhook_authorizer_zip
  source_code_hash = filebase64sha256(local.webhook_authorizer_zip)
  handler          = "index.githubWebhookAuthorizer"
  runtime          = "nodejs24.x"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = 5

  environment {
    variables = {
      # Powertools v2 matches LOG_LEVEL against uppercase keys only and falls
      # back to INFO on anything else, so the value has to be uppercase.
      LOG_LEVEL               = "INFO"
      POWERTOOLS_SERVICE_NAME = local.webhook_authorizer_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.webhook_authorizer,
    aws_iam_role_policy.webhook_authorizer_logging,
  ]
}

resource "aws_apigatewayv2_authorizer" "webhook" {
  api_id                            = module.runners.webhook.gateway.id
  name                              = local.webhook_authorizer_name
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.webhook_authorizer.invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true

  # No identity source on purpose. With one configured, API Gateway answers 401
  # without invoking the lambda whenever that header is absent; an empty list
  # keeps every request on the lambda, which always allows.
  identity_sources = []

  # Caching needs an identity source to key on, so it stays disabled.
  authorizer_result_ttl_in_seconds = 0
}

resource "aws_lambda_permission" "webhook_authorizer" {
  statement_id  = "AllowExecutionFromAPIGatewayAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook_authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${module.runners.webhook.gateway.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.webhook.id}"
}

# `update-route` is an in-place update, so the route is never recreated and no
# delivery window opens. The attach step verifies the result and restores an
# open route if the authorizer turns out to reject traffic.
resource "terraform_data" "webhook_authorizer_attachment" {
  # The permission has to exist before the route routes through the authorizer,
  # otherwise API Gateway cannot invoke it and answers 500 to GitHub.
  depends_on = [aws_lambda_permission.webhook_authorizer]

  input = {
    api_id        = module.runners.webhook.gateway.id
    authorizer_id = aws_apigatewayv2_authorizer.webhook.id
    endpoint      = module.runners.webhook.endpoint
    region        = local.aws_region
    route_key     = local.webhook_route_key
  }

  triggers_replace = [
    module.runners.webhook.gateway.id,
    aws_apigatewayv2_authorizer.webhook.id,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = join(" ", [
      "${path.module}/scripts/webhook-authorizer.sh attach",
      "--api-id ${self.input.api_id}",
      "--authorizer-id ${self.input.authorizer_id}",
      "--region ${self.input.region}",
      "--route-key '${self.input.route_key}'",
      "--endpoint ${self.input.endpoint}",
    ])
  }

  # Best effort: when the whole API is being destroyed the route is already gone.
  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["bash", "-c"]
    command = join(" ", [
      "${path.module}/scripts/webhook-authorizer.sh detach",
      "--api-id ${self.input.api_id}",
      "--region ${self.input.region}",
      "--route-key '${self.input.route_key}'",
    ])
  }
}
