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
  description = "Email address for the budget alerts. Leave empty to skip the budget."
  type        = string
  default     = ""
}

variable "budget_limit_usd" {
  description = "Monthly budget in USD. Set this to the remaining credit of the sandbox account."
  type        = number
  default     = 50
}
