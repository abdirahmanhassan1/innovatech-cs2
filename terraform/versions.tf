terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    wireguard = {
      source  = "OJFord/wireguard"
      version = "~> 0.3"
    }
  }

  # Same state bucket as Case Study 1, separate key. use_lockfile enables native S3 state locking.
  backend "s3" {
    bucket       = "innovatech-cs1-tfstate-hassan"
    key          = "cs2/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
