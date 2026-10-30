# Innovatech Case Study 2: hybrid cloud, monitoring and SOAR

Infrastructure code for Case Study 2 of MA-NCA01 (Fontys ICT). The design and the reasoning behind each choice are in the Case Study 2 design document.

## Overview

- **Office VPC (10.10.0.0/16):** simulated on-premises office with `onprem-gw` (VPN, NAT, firewall) and `onprem-srv`.
- **Cloud VPC (10.20.0.0/16):** `cloud-edge` (VPN, NAT, SSH jump host) and the monitoring server.
- **VPN:** WireGuard tunnel between `onprem-gw` and `cloud-edge`, UDP 51820.
- **DNS:** Route 53 private hosted zone `innovatech.internal`, linked to both VPCs.

## Structure

| Folder | Contents |
| --- | --- |
| `terraform/` | All AWS resources |
| `ansible/` | Server configuration and updates (planned) |
| `soar/` | SOAR functions, rules and tests (planned) |
| `grafana/` | Dashboards and alert rules (planned) |
| `.github/workflows/` | Pipelines on the self-hosted runner (planned) |

## Usage

Terraform is run from AWS CloudShell. State is stored in S3 with native state locking.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in admin_cidr, key_name, ami_id
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

No secrets are stored in this repository. `terraform.tfvars` and key files are excluded through `.gitignore`.
