# Private DNS zone, linked to both VPCs. Not visible from the internet.

resource "aws_route53_zone" "internal" {
  name    = "innovatech.internal"
  comment = "Private zone for the Innovatech hybrid network"

  vpc {
    vpc_id = aws_vpc.office.id
  }

  vpc {
    vpc_id = aws_vpc.cloud.id
  }
}

locals {
  dns_records = {
    "onprem-gw"  = local.onprem_gw_ip
    "onprem-srv" = local.onprem_srv_ip
    "cloud-edge" = local.cloud_edge_ip
  }
}

resource "aws_route53_record" "hosts" {
  for_each = local.dns_records
  zone_id  = aws_route53_zone.internal.zone_id
  name     = "${each.key}.innovatech.internal"
  type     = "A"
  ttl      = 300
  records  = [each.value]
}
