# Layer 1: security groups. Each server only accepts the traffic it needs.
# Descriptions avoid apostrophes and semicolons, which AWS does not accept.

resource "aws_security_group" "onprem_gw" {
  name        = "onprem-gw-sg"
  description = "Office gateway: VPN from cloud-edge, SSH from the internet, traffic from the office network"
  vpc_id      = aws_vpc.office.id

  # All internet traffic is let through to onprem-gw on purpose. onprem-gw simulates
  # the office edge router, the first device a real office receives internet traffic on.
  # nftables on onprem-gw is the actual firewall: default deny, only SSH (key-based) and
  # the VPN are open, and every dropped packet is logged for the monitoring and the SOAR.
  ingress {
    description = "All internet traffic, filtered and logged by nftables on onprem-gw"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "WireGuard from cloud-edge"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["${aws_eip.cloud_edge.public_ip}/32"]
  }

  ingress {
    description = "All traffic from the office network, for NAT and the tunnel"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.office_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "onprem-gw-sg", Site = "office" }
}

resource "aws_security_group" "onprem_srv" {
  name        = "onprem-srv-sg"
  description = "Office server: SSH and monitoring only from inside the hybrid network"
  vpc_id      = aws_vpc.office.id

  ingress {
    description = "SSH through the tunnel via cloud-edge, and from onprem-gw"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.tunnel_cidr, local.office_public_subnet]
  }

  ingress {
    description = "node_exporter scraped by the monitoring server"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.cloud_cidr]
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

  tags = { Name = "onprem-srv-sg", Site = "office" }
}

resource "aws_security_group" "cloud_edge" {
  name        = "cloud-edge-sg"
  description = "Cloud gateway and SSH jump host: VPN from onprem-gw, SSH from admin, traffic from the cloud network"
  vpc_id      = aws_vpc.cloud.id

  ingress {
    description = "SSH from admin laptop"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Ping from admin laptop"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "WireGuard from onprem-gw"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["${aws_eip.onprem_gw.public_ip}/32"]
  }

  ingress {
    description = "All traffic from the cloud network, for NAT and the tunnel"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.cloud_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cloud-edge-sg", Site = "cloud" }
}

# Layer 2: network ACL on the office public subnet, the perimeter firewall.
# The network ACL is the block list of the office. It allows all traffic, and the SOAR
# adds deny rules for attackers with numbers 1 to 99, which are evaluated first.
# Rules are separate resources on purpose: Terraform only manages the rules defined
# here, so an apply never removes an active block.

resource "aws_network_acl" "office_public" {
  vpc_id     = aws_vpc.office.id
  subnet_ids = [aws_subnet.office_public.id]
  tags       = { Name = "office-perimeter-nacl", Site = "office" }
}

locals {
  office_nacl_ingress = {
    "100" = { protocol = "-1", cidr = var.office_cidr, from = 0, to = 0 } # office network
    "200" = { protocol = "-1", cidr = "0.0.0.0/0", from = 0, to = 0 }     # internet, after the SOAR deny rules
  }
}

resource "aws_network_acl_rule" "office_public_in" {
  for_each       = local.office_nacl_ingress
  network_acl_id = aws_network_acl.office_public.id
  rule_number    = tonumber(each.key)
  egress         = false
  protocol       = each.value.protocol
  rule_action    = "allow"
  cidr_block     = each.value.cidr
  from_port      = each.value.protocol == "1" ? null : each.value.from
  to_port        = each.value.protocol == "1" ? null : each.value.to
  icmp_type      = each.value.protocol == "1" ? -1 : null
  icmp_code      = each.value.protocol == "1" ? -1 : null
}

resource "aws_network_acl_rule" "office_public_out" {
  network_acl_id = aws_network_acl.office_public.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# Layer 3 is nftables on the gateways, see templates/gateway.sh.tftpl.
