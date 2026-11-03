# Serverless SOAR: API Gateway receives the Grafana webhook, the ingest function puts
# events in SQS, the processor function decides and acts, DynamoDB keeps the history.
# The SOAR runs on Lambda, not on the EC2 servers it protects.

locals {
  soar_name     = "innovatech-soar"
  soar_src      = "${path.module}/../soar/src"
  gateway_cidrs = "${aws_eip.onprem_gw.public_ip}/32,${aws_eip.cloud_edge.public_ip}/32"
  nacl_arn      = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:network-acl/${aws_network_acl.office_public.id}"
}

# One package for the three functions. The rules file is part of the package.
data "archive_file" "soar" {
  type        = "zip"
  output_path = "${path.module}/build/soar.zip"

  source {
    content  = file("${local.soar_src}/soar_common.py")
    filename = "soar_common.py"
  }
  source {
    content  = file("${local.soar_src}/ingest.py")
    filename = "ingest.py"
  }
  source {
    content  = file("${local.soar_src}/processor.py")
    filename = "processor.py"
  }
  source {
    content  = file("${local.soar_src}/cleanup.py")
    filename = "cleanup.py"
  }
  source {
    content  = file("${path.module}/../soar/rules/rules.json")
    filename = "rules.json"
  }
}

# ---------- Storage ----------

# A1: every event and decision. Deleted automatically after the retention period (TTL).
resource "aws_dynamodb_table" "events" {
  name         = "${local.soar_name}-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  ttl {
    attribute_name = "expire_at"
    enabled        = true
  }
}

# Active blocks: one item per blocked address, with its network ACL rule number and end time.
resource "aws_dynamodb_table" "blocks" {
  name         = "${local.soar_name}-blocks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ip"

  attribute {
    name = "ip"
    type = "S"
  }
}

# ---------- Queues ----------

resource "aws_sqs_queue" "soar_dlq" {
  name                      = "${local.soar_name}-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "soar_events" {
  name                       = "${local.soar_name}-events"
  visibility_timeout_seconds = 180 # six times the processor timeout
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.soar_dlq.arn
    maxReceiveCount     = 3
  })
}

# ---------- Permissions (one role per function, least privilege) ----------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "soar" {
  for_each           = toset(["ingest", "processor", "cleanup"])
  name               = "${local.soar_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "soar_logs" {
  for_each   = aws_iam_role.soar
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "ingest" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.soar_events.arn]
  }
}

data "aws_iam_policy_document" "processor" {
  statement {
    sid       = "ReadQueue"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.soar_events.arn]
  }
  statement {
    sid       = "RecordAndTrackBlocks"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Scan"]
    resources = [aws_dynamodb_table.events.arn, aws_dynamodb_table.blocks.arn]
  }
  statement {
    sid       = "BlockOnOfficeNacl"
    actions   = ["ec2:CreateNetworkAclEntry", "ec2:DeleteNetworkAclEntry"]
    resources = [local.nacl_arn]
  }
  statement {
    sid       = "Notify"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

data "aws_iam_policy_document" "cleanup" {
  statement {
    actions   = ["dynamodb:Scan", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.blocks.arn]
  }
  statement {
    actions   = ["ec2:DeleteNetworkAclEntry"]
    resources = [local.nacl_arn]
  }
}

resource "aws_iam_role_policy" "ingest" {
  name   = "ingest"
  role   = aws_iam_role.soar["ingest"].id
  policy = data.aws_iam_policy_document.ingest.json
}

resource "aws_iam_role_policy" "processor" {
  name   = "processor"
  role   = aws_iam_role.soar["processor"].id
  policy = data.aws_iam_policy_document.processor.json
}

resource "aws_iam_role_policy" "cleanup" {
  name   = "cleanup"
  role   = aws_iam_role.soar["cleanup"].id
  policy = data.aws_iam_policy_document.cleanup.json
}

# ---------- Functions ----------

# Logs contain IP addresses, so they are kept for 30 days only.
resource "aws_cloudwatch_log_group" "soar" {
  for_each          = toset(["ingest", "processor", "cleanup"])
  name              = "/aws/lambda/${local.soar_name}-${each.key}"
  retention_in_days = 30
}

resource "aws_lambda_function" "ingest" {
  function_name    = "${local.soar_name}-ingest"
  role             = aws_iam_role.soar["ingest"].arn
  runtime          = "python3.12"
  handler          = "ingest.handler"
  filename         = data.archive_file.soar.output_path
  source_code_hash = data.archive_file.soar.output_base64sha256
  timeout          = 10
  publish          = true

  environment {
    variables = {
      QUEUE_URL     = aws_sqs_queue.soar_events.url
      WEBHOOK_TOKEN = var.soar_webhook_token
    }
  }

  # After the first deployment, the code is released by the soar-release pipeline.
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }

  depends_on = [aws_cloudwatch_log_group.soar, aws_iam_role_policy_attachment.soar_logs]
}

# Release management: every function publishes versions, and the aliases "test" and "prod"
# point to a version. Terraform creates the functions and aliases. After that, the
# soar-release pipeline deploys new code and moves the aliases (test first, prod after
# approval), so Terraform ignores the code and the alias versions.
# For the processor, the invoked alias also decides the environment (block time, allow list).
resource "aws_lambda_function" "processor" {
  function_name    = "${local.soar_name}-processor"
  role             = aws_iam_role.soar["processor"].arn
  runtime          = "python3.12"
  handler          = "processor.handler"
  filename         = data.archive_file.soar.output_path
  source_code_hash = data.archive_file.soar.output_base64sha256
  timeout          = 30
  publish          = true

  environment {
    variables = {
      EVENTS_TABLE  = aws_dynamodb_table.events.name
      BLOCKS_TABLE  = aws_dynamodb_table.blocks.name
      NACL_ID       = aws_network_acl.office_public.id
      TOPIC_ARN     = aws_sns_topic.alerts.arn
      ADMIN_CIDR    = var.admin_cidr
      GATEWAY_CIDRS = local.gateway_cidrs
    }
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }

  depends_on = [aws_cloudwatch_log_group.soar, aws_iam_role_policy_attachment.soar_logs]
}

resource "aws_lambda_alias" "processor" {
  for_each         = toset(["test", "prod"])
  name             = each.key
  function_name    = aws_lambda_function.processor.function_name
  function_version = aws_lambda_function.processor.version

  lifecycle {
    ignore_changes = [function_version]
  }
}

resource "aws_lambda_function" "cleanup" {
  function_name    = "${local.soar_name}-cleanup"
  role             = aws_iam_role.soar["cleanup"].arn
  runtime          = "python3.12"
  handler          = "cleanup.handler"
  filename         = data.archive_file.soar.output_path
  source_code_hash = data.archive_file.soar.output_base64sha256
  timeout          = 30
  publish          = true

  environment {
    variables = {
      BLOCKS_TABLE = aws_dynamodb_table.blocks.name
      NACL_ID      = aws_network_acl.office_public.id
    }
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }

  depends_on = [aws_cloudwatch_log_group.soar, aws_iam_role_policy_attachment.soar_logs]
}

# Aliases for the ingest and cleanup functions. The triggers (API Gateway, EventBridge)
# call the "prod" alias, so a new version only reaches production after approval.
resource "aws_lambda_alias" "ingest" {
  for_each         = toset(["test", "prod"])
  name             = each.key
  function_name    = aws_lambda_function.ingest.function_name
  function_version = aws_lambda_function.ingest.version

  lifecycle {
    ignore_changes = [function_version]
  }
}

resource "aws_lambda_alias" "cleanup" {
  for_each         = toset(["test", "prod"])
  name             = each.key
  function_name    = aws_lambda_function.cleanup.function_name
  function_version = aws_lambda_function.cleanup.version

  lifecycle {
    ignore_changes = [function_version]
  }
}

# Production events from the queue go to the "prod" alias. A failed event is retried,
# and after three attempts it moves to the dead-letter queue.
resource "aws_lambda_event_source_mapping" "processor" {
  event_source_arn        = aws_sqs_queue.soar_events.arn
  function_name           = aws_lambda_alias.processor["prod"].arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 2
  }
}

# ---------- API Gateway ----------

resource "aws_apigatewayv2_api" "soar" {
  name          = local.soar_name
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "ingest" {
  api_id                 = aws_apigatewayv2_api.soar.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_alias.ingest["prod"].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "alerts" {
  api_id    = aws_apigatewayv2_api.soar.id
  route_key = "POST /alerts"
  target    = "integrations/${aws_apigatewayv2_integration.ingest.id}"
}

resource "aws_cloudwatch_log_group" "soar_api" {
  name              = "/aws/apigateway/${local.soar_name}"
  retention_in_days = 30
}

# The rate limit protects the SOAR against a flood of requests. SQS buffers the rest.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.soar.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.soar_api.arn
    format = jsonencode({
      time    = "$context.requestTime"
      ip      = "$context.identity.sourceIp"
      route   = "$context.routeKey"
      status  = "$context.status"
      latency = "$context.integrationLatency"
      request = "$context.requestId"
    })
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  qualifier     = aws_lambda_alias.ingest["prod"].name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.soar.execution_arn}/*/*"
}

# ---------- Cleanup every minute ----------

resource "aws_cloudwatch_event_rule" "cleanup" {
  name                = "${local.soar_name}-cleanup"
  description         = "Removes expired SOAR blocks from the office network ACL"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "cleanup" {
  rule = aws_cloudwatch_event_rule.cleanup.name
  arn  = aws_lambda_alias.cleanup["prod"].arn
}

resource "aws_lambda_permission" "cleanup" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cleanup.function_name
  qualifier     = aws_lambda_alias.cleanup["prod"].name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cleanup.arn
}

# ---------- Monitoring the SOAR itself ----------

resource "aws_cloudwatch_metric_alarm" "soar_dlq" {
  alarm_name          = "${local.soar_name}-failed-events"
  alarm_description   = "Events that failed three times are in the dead-letter queue"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.soar_dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "soar_errors" {
  for_each            = { ingest = aws_lambda_function.ingest.function_name, processor = aws_lambda_function.processor.function_name, cleanup = aws_lambda_function.cleanup.function_name }
  alarm_name          = "${local.soar_name}-${each.key}-errors"
  alarm_description   = "The SOAR ${each.key} function reported errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
