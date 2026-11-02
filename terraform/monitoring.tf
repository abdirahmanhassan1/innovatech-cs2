# Monitoring server: Prometheus, Loki and Grafana on one instance in an Auto Scaling
# group across two availability zones. Logs are stored in S3, configuration comes
# from the repository, so a replacement server starts with the same setup.

data "aws_caller_identity" "current" {}

# ---------- Log storage (Loki) ----------

resource "aws_s3_bucket" "loki" {
  bucket        = "innovatech-cs2-loki-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "loki-log-storage", Site = "cloud" }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Loki deletes logs after 90 days (retention in loki.yaml). This rule is a safety net
# so log data with IP addresses is never kept much longer, see the data lifecycle analysis.
resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    id     = "expire-log-data"
    status = "Enabled"
    filter {}
    expiration {
      days = 100
    }
  }
}

# ---------- Permissions (least privilege) ----------

data "aws_iam_policy_document" "monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "monitoring" {
  statement {
    sid       = "LokiBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.loki.arn]
  }
  statement {
    sid       = "LokiObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.loki.arn}/*"]
  }
  statement {
    sid       = "AlertEmail"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
  statement {
    sid       = "OwnDnsRecord"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [aws_route53_zone.internal.arn]
  }
  statement {
    sid = "ReadOnlyMetrics"
    actions = [
      "route53:GetChange",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms",
      "ec2:DescribeRegions",
      "ec2:DescribeInstances",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "monitoring" {
  name               = "innovatech-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json
}

resource "aws_iam_role_policy" "monitoring" {
  name   = "innovatech-monitoring"
  role   = aws_iam_role.monitoring.id
  policy = data.aws_iam_policy_document.monitoring.json
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "innovatech-monitoring"
  role = aws_iam_role.monitoring.name
}

# ---------- Network access ----------

resource "aws_security_group" "monitoring" {
  name        = "monitoring-sg"
  description = "Monitoring server: logs from all hosts, Grafana and SSH only through cloud-edge"
  vpc_id      = aws_vpc.cloud.id

  ingress {
    description = "SSH from cloud-edge, the jump host"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${local.cloud_edge_ip}/32"]
  }

  ingress {
    description = "Grafana through an SSH tunnel via cloud-edge"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["${local.cloud_edge_ip}/32"]
  }

  ingress {
    description = "Logs pushed to Loki by Alloy on every host"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = [var.office_cidr, var.cloud_cidr, var.tunnel_cidr]
  }

  ingress {
    description = "Ping from the hybrid network"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.office_cidr, var.cloud_cidr, var.tunnel_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "monitoring-sg", Site = "cloud" }
}

# ---------- DNS ----------

# The record is created here so Terraform can remove it again. The server itself
# updates the address at boot, because a replacement server gets a new IP address.
resource "aws_route53_record" "monitoring" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "monitoring.innovatech.internal"
  type    = "A"
  ttl     = 60
  records = ["10.20.1.250"]

  lifecycle {
    ignore_changes = [records]
  }
}

# ---------- Server ----------

resource "aws_launch_template" "monitoring" {
  name          = "innovatech-monitoring"
  image_id      = var.ami_id
  instance_type = var.monitoring_instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.monitoring.name
  }

  vpc_security_group_ids = [aws_security_group.monitoring.id]

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/monitoring.sh.tftpl", {
    region                 = var.region
    repo_url               = var.repo_url
    repo_branch            = var.repo_branch
    loki_bucket            = aws_s3_bucket.loki.bucket
    sns_topic_arn          = aws_sns_topic.alerts.arn
    zone_id                = aws_route53_zone.internal.zone_id
    grafana_admin_password = var.grafana_admin_password
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "monitoring", Role = "monitoring", Site = "cloud", Project = var.project }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "monitoring", Project = var.project }
  }
}

resource "aws_autoscaling_group" "monitoring" {
  name                      = "innovatech-monitoring"
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  vpc_zone_identifier       = aws_subnet.cloud_private[*].id
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.monitoring.id
    version = aws_launch_template.monitoring.latest_version
  }

  # A change to the launch template replaces the server automatically.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }

  depends_on = [aws_route.cloud_private_default, aws_vpc_endpoint.s3, aws_instance.cloud_edge]
}
