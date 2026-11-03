# Innovatech Case Study 2: hybrid cloud, monitoring and SOAR

Infrastructure code for Case Study 2 of MA-NCA01 (Fontys ICT). The design and the reasoning behind each choice are in the Case Study 2 design document.

## Overview

- **Office VPC (10.10.0.0/16):** simulated on-premises office with `onprem-gw` (VPN, NAT, firewall) and `onprem-srv`.
- **Cloud VPC (10.20.0.0/16):** `cloud-edge` (VPN, NAT, SSH jump host) and the monitoring server.
- **VPN:** WireGuard tunnel between `onprem-gw` and `cloud-edge`, UDP 51820.
- **DNS:** Route 53 private hosted zone `innovatech.internal`, linked to both VPCs.
- **Monitoring:** Prometheus, Loki (log storage in S3) and Grafana on a monitoring server in an Auto Scaling group across two availability zones. node_exporter and Grafana Alloy run on every host.
- **SOAR:** serverless (API Gateway, Lambda, SQS, DynamoDB). Security alerts from Grafana are processed by a rule engine with three response levels: record, notify and block (a deny rule on the office network ACL).

## Structure

| Folder | Contents |
| --- | --- |
| `terraform/` | All AWS resources |
| `ansible/` | Server configuration: monitoring agents, monitoring server, updates |
| `monitoring/` | Prometheus, Loki and Alloy configuration |
| `soar/` | SOAR functions (`src/`), response rules (`rules/`), unit and smoke tests (`tests/`), build script (`scripts/`) |
| `grafana/` | Data sources, dashboards and alert rules |
| `.github/workflows/` | Pipelines on the self-hosted runner |

## Usage

Changes are applied through the `infra` pipeline (see Pipelines). Terraform can also be run from AWS CloudShell, for example for the first deployment. State is stored in S3 with native state locking.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in admin_cidr, key_name, ami_id
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

The monitoring server reads `monitoring/` and `grafana/` from the `main` branch at boot, so configuration changes are merged before they are applied.

Monitoring agents on the existing hosts are installed with Ansible:

```bash
cd ansible
ansible-playbook agents.yml
```

Configuration changes for the running monitoring server are merged to `main` first and then applied with:

```bash
ansible-playbook monitoring.yml
```

Grafana is not public. It is opened through an SSH tunnel (see the Terraform output `grafana_tunnel`).

The SOAR rule engine is tested without AWS:

```bash
python3 -m unittest discover -s soar/tests -v
```

## Pipelines

The pipelines run on a self-hosted GitHub Actions runner on the admin laptop (label `innovatech`). They get temporary AWS credentials through OIDC, so no AWS access keys are stored anywhere. Pull requests from forks never run on the runner.

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `infra` | Pull request or merge that changes `terraform/` | Format check, validate and plan. After a merge, the plan is applied after approval in the `production` environment. |
| `soar-release` | Pull request or merge that changes `soar/` | Unit tests. After a merge: a new version of each function, the `test` aliases are moved and smoke tested, and the `prod` aliases are moved after approval. |
| `soar-rollback` | Manual | Points the `prod` aliases back to the previous version, after approval. |
| `updates` | Every Monday and manual | Runs `ansible/update.yml` on all servers (one at a time) and keeps the update report. |

| AWS role | Used by | Rights |
| --- | --- | --- |
| `innovatech-github-plan` | Pull requests and read-only jobs on `main` | Read-only, plus the Terraform state lock |
| `innovatech-github-deploy` | `infra` apply, `production` environment only | Administrator, because Terraform also manages IAM |
| `innovatech-github-release` | `soar-release` and `soar-rollback` | Deploy, publish and alias the SOAR functions only |

Terraform creates the SOAR functions and their aliases. After that, the code and the alias versions are managed by `soar-release`, so Terraform ignores them.

Repository settings used by the workflows: secrets `ADMIN_CIDR`, `BUDGET_EMAIL`, `GRAFANA_ADMIN_PASSWORD` and `SOAR_WEBHOOK_TOKEN`; variables `AWS_ACCOUNT_ID`, `KEY_NAME`, `AMI_ID` and `BUDGET_LIMIT_USD`; environments `soar-test` and `production` (required reviewer, `main` only).

No secrets are stored in this repository. `terraform.tfvars` (including the Grafana password and the SOAR webhook token) and key files are excluded through `.gitignore`.
