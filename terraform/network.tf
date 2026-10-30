# Two VPCs: the simulated office and the cloud. The address ranges do not overlap,
# so traffic can be routed between them through the VPN tunnel.

locals {
  office_public_subnet  = cidrsubnet(var.office_cidr, 8, 0) # 10.10.0.0/24
  office_private_subnet = cidrsubnet(var.office_cidr, 8, 1) # 10.10.1.0/24
  cloud_public_subnet   = cidrsubnet(var.cloud_cidr, 8, 0)  # 10.20.0.0/24
  cloud_private_subnets = [cidrsubnet(var.cloud_cidr, 8, 1), cidrsubnet(var.cloud_cidr, 8, 2)]

  onprem_gw_ip  = cidrhost(local.office_public_subnet, 10)  # 10.10.0.10
  onprem_srv_ip = cidrhost(local.office_private_subnet, 10) # 10.10.1.10
  cloud_edge_ip = cidrhost(local.cloud_public_subnet, 10)   # 10.20.0.10

  onprem_gw_tunnel_ip  = cidrhost(var.tunnel_cidr, 1) # 172.16.99.1
  cloud_edge_tunnel_ip = cidrhost(var.tunnel_cidr, 2) # 172.16.99.2
}

# ---------- Office VPC ----------

resource "aws_vpc" "office" {
  cidr_block           = var.office_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "office-vpc", Site = "office" }
}

resource "aws_internet_gateway" "office" {
  vpc_id = aws_vpc.office.id
  tags   = { Name = "office-igw", Site = "office" }
}

resource "aws_subnet" "office_public" {
  vpc_id            = aws_vpc.office.id
  cidr_block        = local.office_public_subnet
  availability_zone = var.azs[0]
  tags              = { Name = "office-public", Site = "office" }
}

resource "aws_subnet" "office_private" {
  vpc_id            = aws_vpc.office.id
  cidr_block        = local.office_private_subnet
  availability_zone = var.azs[0]
  tags              = { Name = "office-private", Site = "office" }
}

resource "aws_route_table" "office_public" {
  vpc_id = aws_vpc.office.id
  tags   = { Name = "office-public-rt", Site = "office" }
}

resource "aws_route" "office_public_internet" {
  route_table_id         = aws_route_table.office_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.office.id
}

resource "aws_route_table_association" "office_public" {
  subnet_id      = aws_subnet.office_public.id
  route_table_id = aws_route_table.office_public.id
}

# The private subnet has no internet gateway route. All traffic goes to onprem-gw,
# which sends cloud traffic through the tunnel and NATs internet traffic.
resource "aws_route_table" "office_private" {
  vpc_id = aws_vpc.office.id
  tags   = { Name = "office-private-rt", Site = "office" }
}

resource "aws_route" "office_private_default" {
  route_table_id         = aws_route_table.office_private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.onprem_gw.id
}

resource "aws_route" "office_private_to_cloud" {
  route_table_id         = aws_route_table.office_private.id
  destination_cidr_block = var.cloud_cidr
  network_interface_id   = aws_network_interface.onprem_gw.id
}

resource "aws_route_table_association" "office_private" {
  subnet_id      = aws_subnet.office_private.id
  route_table_id = aws_route_table.office_private.id
}

# ---------- Cloud VPC ----------

resource "aws_vpc" "cloud" {
  cidr_block           = var.cloud_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "cloud-vpc", Site = "cloud" }
}

resource "aws_internet_gateway" "cloud" {
  vpc_id = aws_vpc.cloud.id
  tags   = { Name = "cloud-igw", Site = "cloud" }
}

resource "aws_subnet" "cloud_public" {
  vpc_id            = aws_vpc.cloud.id
  cidr_block        = local.cloud_public_subnet
  availability_zone = var.azs[0]
  tags              = { Name = "cloud-public", Site = "cloud" }
}

resource "aws_subnet" "cloud_private" {
  count             = 2
  vpc_id            = aws_vpc.cloud.id
  cidr_block        = local.cloud_private_subnets[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "cloud-private-${count.index + 1}", Site = "cloud" }
}

resource "aws_route_table" "cloud_public" {
  vpc_id = aws_vpc.cloud.id
  tags   = { Name = "cloud-public-rt", Site = "cloud" }
}

resource "aws_route" "cloud_public_internet" {
  route_table_id         = aws_route_table.cloud_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.cloud.id
}

resource "aws_route_table_association" "cloud_public" {
  subnet_id      = aws_subnet.cloud_public.id
  route_table_id = aws_route_table.cloud_public.id
}

resource "aws_route_table" "cloud_private" {
  vpc_id = aws_vpc.cloud.id
  tags   = { Name = "cloud-private-rt", Site = "cloud" }
}

resource "aws_route" "cloud_private_default" {
  route_table_id         = aws_route_table.cloud_private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.cloud_edge.id
}

resource "aws_route" "cloud_private_to_office" {
  route_table_id         = aws_route_table.cloud_private.id
  destination_cidr_block = var.office_cidr
  network_interface_id   = aws_network_interface.cloud_edge.id
}

resource "aws_route_table_association" "cloud_private" {
  count          = 2
  subnet_id      = aws_subnet.cloud_private[count.index].id
  route_table_id = aws_route_table.cloud_private.id
}

# S3 traffic from the private subnets (Loki storage) stays inside AWS.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.cloud.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.cloud_private.id]
  tags              = { Name = "cloud-s3-endpoint", Site = "cloud" }
}
