variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Project tag, used to see the Case Study 2 costs separately."
  type        = string
  default     = "innovatech-cs2"
}

variable "azs" {
  description = "Two availability zones. The first one is used for the gateways and the office server."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]
}

variable "admin_cidr" {
  description = "Public IP address of the admin laptop in CIDR notation, for example 203.0.113.10/32. Check it at the start of every session from the laptop, not from CloudShell."
  type        = string
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access."
  type        = string
}

variable "ami_id" {
  description = "Fixed Ubuntu 24.04 AMI ID. Pinned on purpose, so a new image release never replaces running servers."
  type        = string
}

variable "small_instance_type" {
  description = "Instance type for the gateways and the office server."
  type        = string
  default     = "t3.micro"
}

# Address plan, see section 1 of the design document.
variable "office_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "cloud_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "tunnel_cidr" {
  description = "Addresses inside the WireGuard tunnel."
  type        = string
  default     = "172.16.99.0/30"
}

variable "budget_email" {
  description = "Email address for the budget alerts and the monitoring alerts. Leave empty to skip the budget."
  type        = string
  default     = ""
}

variable "budget_limit_usd" {
  description = "Monthly budget in USD. Set this to the remaining credit of the sandbox account."
  type        = number
  default     = 50
}

# ---------- Monitoring (step 2) ----------

variable "monitoring_instance_type" {
  description = "Instance type for the monitoring server (Prometheus, Loki, Grafana)."
  type        = string
  default     = "t3.medium"
}

variable "grafana_admin_password" {
  description = "Password of the Grafana admin user. Set it in terraform.tfvars, never in the repository."
  type        = string
  sensitive   = true
}

variable "repo_url" {
  description = "Public repository the monitoring server reads its configuration from at boot."
  type        = string
  default     = "https://github.com/abdirahmanhassan1/innovatech-cs2.git"
}

variable "repo_branch" {
  description = "Branch the monitoring server reads its configuration from."
  type        = string
  default     = "main"
}

# ---------- SOAR (step 3) ----------

variable "soar_webhook_token" {
  description = "Shared secret that Grafana sends with every webhook message to the SOAR. Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.soar_webhook_token) >= 32
    error_message = "Use a token of at least 32 characters."
  }
}

# ---------- Pipelines (step 4) ----------

variable "github_repo" {
  description = "GitHub repository (owner/name) whose workflows may use the pipeline roles."
  type        = string
  default     = "abdirahmanhassan1/innovatech-cs2"
}
