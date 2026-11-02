# The two gateways: onprem-gw (office) and cloud-edge (cloud).
# Each runs WireGuard, NAT for its private subnet and an nftables firewall.

# WireGuard key pairs. The private keys are stored in the encrypted state bucket
# and passed to the gateways through user data (see section 9 of the design, limitations).
resource "wireguard_asymmetric_key" "onprem_gw" {}
resource "wireguard_asymmetric_key" "cloud_edge" {}

# Fixed public addresses. Allocated separately from their association, so the
# security groups of both gateways can refer to the address of the other one.
resource "aws_eip" "onprem_gw" {
  domain = "vpc"
  tags   = { Name = "onprem-gw-eip", Site = "office" }
}

resource "aws_eip" "cloud_edge" {
  domain = "vpc"
  tags   = { Name = "cloud-edge-eip", Site = "cloud" }
}

# Network interfaces are created first, so the public address is attached
# before the server boots and the startup script can download packages.
# source_dest_check is off because the gateways forward traffic for other hosts.
resource "aws_network_interface" "onprem_gw" {
  subnet_id         = aws_subnet.office_public.id
  private_ips       = [local.onprem_gw_ip]
  security_groups   = [aws_security_group.onprem_gw.id]
  source_dest_check = false
  tags              = { Name = "onprem-gw-eni", Site = "office" }
}

resource "aws_network_interface" "cloud_edge" {
  subnet_id         = aws_subnet.cloud_public.id
  private_ips       = [local.cloud_edge_ip]
  security_groups   = [aws_security_group.cloud_edge.id]
  source_dest_check = false
  tags              = { Name = "cloud-edge-eni", Site = "cloud" }
}

resource "aws_eip_association" "onprem_gw" {
  allocation_id        = aws_eip.onprem_gw.id
  network_interface_id = aws_network_interface.onprem_gw.id
}

resource "aws_eip_association" "cloud_edge" {
  allocation_id        = aws_eip.cloud_edge.id
  network_interface_id = aws_network_interface.cloud_edge.id
}

resource "aws_instance" "onprem_gw" {
  ami           = var.ami_id
  instance_type = var.small_instance_type
  key_name      = var.key_name

  network_interface {
    network_interface_id = aws_network_interface.onprem_gw.id
    device_index         = 0
  }

  user_data = templatefile("${path.module}/templates/gateway.sh.tftpl", {
    hostname         = "onprem-gw"
    local_cidr       = var.office_cidr
    tunnel_address   = "${local.onprem_gw_tunnel_ip}/30"
    private_key      = wireguard_asymmetric_key.onprem_gw.private_key
    peer_public_key  = wireguard_asymmetric_key.cloud_edge.public_key
    peer_endpoint    = aws_eip.cloud_edge.public_ip
    peer_allowed_ips = "${var.tunnel_cidr}, ${var.cloud_cidr}"
  })
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "onprem-gw", Role = "gateway", Site = "office" }

  depends_on = [aws_eip_association.onprem_gw, aws_route.office_public_internet]
}

resource "aws_instance" "cloud_edge" {
  ami           = var.ami_id
  instance_type = var.small_instance_type
  key_name      = var.key_name

  network_interface {
    network_interface_id = aws_network_interface.cloud_edge.id
    device_index         = 0
  }

  user_data = templatefile("${path.module}/templates/gateway.sh.tftpl", {
    hostname         = "cloud-edge"
    local_cidr       = var.cloud_cidr
    tunnel_address   = "${local.cloud_edge_tunnel_ip}/30"
    private_key      = wireguard_asymmetric_key.cloud_edge.private_key
    peer_public_key  = wireguard_asymmetric_key.onprem_gw.public_key
    peer_endpoint    = aws_eip.onprem_gw.public_ip
    peer_allowed_ips = "${var.tunnel_cidr}, ${var.office_cidr}"
  })
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "cloud-edge", Role = "gateway", Site = "cloud" }

  depends_on = [aws_eip_association.cloud_edge, aws_route.cloud_public_internet]
}
