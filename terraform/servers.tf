# onprem-srv: the office server that is monitored. Private subnet, no public address.
# It reaches the internet and the cloud through onprem-gw.

resource "aws_instance" "onprem_srv" {
  ami                    = var.ami_id
  instance_type          = var.small_instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.office_private.id
  private_ip             = local.onprem_srv_ip
  vpc_security_group_ids = [aws_security_group.onprem_srv.id]

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl set-hostname onprem-srv
  EOF

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "onprem-srv", Role = "server", Site = "office" }

  depends_on = [aws_route.office_private_default]
}
