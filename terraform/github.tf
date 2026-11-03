# Access for the GitHub Actions pipelines through OpenID Connect (OIDC).
# A workflow job gets a short-lived token from GitHub and exchanges it for temporary
# AWS credentials. No AWS access keys are stored on the runner or in GitHub.
# Each role only trusts this repository, and only for the events listed in its trust policy.

locals {
  github_oidc_host = "token.actions.githubusercontent.com"
  github_owner     = split("/", var.github_repo)[0]
  github_repo_name = split("/", var.github_repo)[1]
  # Immutable subject format: repo:OWNER@OWNER_ID/REPO@REPO_ID, followed by the event,
  # branch or environment, for example repo:owner@1/repo@2:environment:production.
  github_subject = "repo:${local.github_owner}@${var.github_owner_id}/${local.github_repo_name}@${var.github_repo_id}"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub tokens with its own trusted certificate store; the
  # thumbprints are only kept because older API versions required them.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_policy_document" "github_trust" {
  for_each = {
    # Plans for pull requests, and read-only jobs on the main branch (plan, update inventory).
    plan = ["${local.github_subject}:pull_request", "${local.github_subject}:ref:refs/heads/main"]
    # Only jobs in the "production" environment, which needs my approval in GitHub.
    deploy = ["${local.github_subject}:environment:production"]
    # SOAR releases: automatic to test, to production only after approval.
    release = ["${local.github_subject}:environment:soar-test", "${local.github_subject}:environment:production"]
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "github" {
  for_each             = data.aws_iam_policy_document.github_trust
  name                 = "innovatech-github-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

# ---------- plan: read everything, write only the state lock ----------

resource "aws_iam_role_policy_attachment" "github_plan_read" {
  role       = aws_iam_role.github["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "github_plan_lock" {
  statement {
    sid       = "StateLockFile"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::innovatech-cs1-tfstate-hassan/cs2/terraform.tfstate.tflock"]
  }
}

resource "aws_iam_role_policy" "github_plan_lock" {
  name   = "state-lock"
  role   = aws_iam_role.github["plan"].id
  policy = data.aws_iam_policy_document.github_plan_lock.json
}

# ---------- deploy: Terraform apply ----------
# Terraform manages IAM roles as well, so this role needs broad rights. It is protected by
# the trust policy (production environment only) and the manual approval in GitHub.

resource "aws_iam_role_policy_attachment" "github_deploy_admin" {
  role       = aws_iam_role.github["deploy"].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---------- release: SOAR code and aliases only ----------

data "aws_iam_policy_document" "github_release" {
  statement {
    sid = "ReleaseSoarFunctions"
    actions = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:UpdateFunctionCode",
      "lambda:PublishVersion",
      "lambda:ListVersionsByFunction",
      "lambda:GetAlias",
      "lambda:UpdateAlias",
      "lambda:InvokeFunction",
    ]
    resources = [
      "arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:${local.soar_name}-*",
    ]
  }
  statement {
    sid       = "CheckSmokeTestResult"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.events.arn]
  }
}

resource "aws_iam_role_policy" "github_release" {
  name   = "soar-release"
  role   = aws_iam_role.github["release"].id
  policy = data.aws_iam_policy_document.github_release.json
}
