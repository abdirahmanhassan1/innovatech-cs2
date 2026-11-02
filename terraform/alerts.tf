# Alert notifications: one SNS topic for the monitoring alerts and the budget alerts.
# Direct budget emails need a verification step that does not work in the sandbox
# account, so the budget publishes to this topic and SNS sends the email.

resource "aws_sns_topic" "alerts" {
  name = "innovatech-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.budget_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.budget_email
}

# AWS Budgets may publish to the topic, but only for this account.
data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "AllowBudgets"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}
