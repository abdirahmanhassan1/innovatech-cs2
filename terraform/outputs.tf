output "onprem_gw_public_ip" {
  value = aws_eip.onprem_gw.public_ip
}

output "cloud_edge_public_ip" {
  value = aws_eip.cloud_edge.public_ip
}

output "private_ips" {
  value = {
    onprem_gw  = local.onprem_gw_ip
    onprem_srv = local.onprem_srv_ip
    cloud_edge = local.cloud_edge_ip
  }
}

output "ssh_commands" {
  description = "Run ssh-add with the key file first, so the jump through cloud-edge also uses it."
  value = {
    onprem_gw  = "ssh ubuntu@${aws_eip.onprem_gw.public_ip}"
    cloud_edge = "ssh ubuntu@${aws_eip.cloud_edge.public_ip}"
    onprem_srv = "ssh -J ubuntu@${aws_eip.cloud_edge.public_ip} ubuntu@${local.onprem_srv_ip}"
  }
}

output "private_zone_id" {
  value = aws_route53_zone.internal.zone_id
}

output "office_nacl_id" {
  description = "The perimeter network ACL that the SOAR will change."
  value       = aws_network_acl.office_public.id
}
