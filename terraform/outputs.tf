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

output "grafana_tunnel" {
  description = "Opens Grafana on http://localhost:3000 through cloud-edge."
  value       = "ssh -N -L 3000:monitoring.innovatech.internal:3000 ubuntu@${aws_eip.cloud_edge.public_ip}"
}

output "monitoring_ssh" {
  value = "ssh -J ubuntu@${aws_eip.cloud_edge.public_ip} ubuntu@monitoring.innovatech.internal"
}

output "loki_bucket" {
  value = aws_s3_bucket.loki.bucket
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "ansible_inventory" {
  description = "Inventory for ansible/inventory.ini."
  value       = <<-EOT
    [office_gateway]
    onprem-gw ansible_host=${aws_eip.onprem_gw.public_ip}

    [cloud_gateway]
    cloud-edge ansible_host=${aws_eip.cloud_edge.public_ip}

    [office_servers]
    onprem-srv ansible_host=${local.onprem_srv_ip} ansible_ssh_common_args='-o ProxyJump=ubuntu@${aws_eip.cloud_edge.public_ip}'

    [gateways:children]
    office_gateway
    cloud_gateway

    [agents:children]
    gateways
    office_servers
  EOT
}
