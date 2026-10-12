terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

locals {
  name = "wtqrk"

  tags = merge(var.tags, {
    Project   = "william-tells-qr-killer"
    ManagedBy = "terraform"
  })
}

# --------------------------------------------------------------------------
# VPC
# --------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${local.name}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.name}-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.name}-public-rt" })

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

# Public subnets in 2 AZs (ALB requires min 2)
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${local.name}-public-a" })
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = var.secondary_az
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${local.name}-public-b" })
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# --------------------------------------------------------------------------
# AMI
# --------------------------------------------------------------------------

data "aws_ami" "macos" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn-ec2-macos-14*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64_mac"]
  }
}

# --------------------------------------------------------------------------
# ACM Certificate
# --------------------------------------------------------------------------

resource "aws_acm_certificate" "cert" {
  domain_name       = var.hostname
  validation_method = "DNS"
  tags              = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = var.hosted_zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# --------------------------------------------------------------------------
# Security Groups
# --------------------------------------------------------------------------

resource "aws_security_group" "mac" {
  name_prefix = "${local.name}-mac-"
  description = "Mac instance"
  vpc_id      = aws_vpc.main.id
  tags        = local.tags

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
  }

  ingress {
    description     = "App from ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "alb" {
  name_prefix = "${local.name}-alb-"
  description = "ALB"
  vpc_id      = aws_vpc.main.id
  tags        = local.tags

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --------------------------------------------------------------------------
# Dedicated Host (24hr minimum allocation — Apple licensing requirement)
# --------------------------------------------------------------------------

resource "aws_ec2_host" "mac" {
  instance_type     = var.instance_type
  availability_zone = var.availability_zone
  auto_placement    = "on"
  tags              = merge(local.tags, { Name = "${local.name}-host" })
}

# --------------------------------------------------------------------------
# EC2 Mac Instance
# --------------------------------------------------------------------------

resource "aws_instance" "mac" {
  ami               = data.aws_ami.macos.id
  instance_type     = var.instance_type
  host_id           = aws_ec2_host.mac.id
  subnet_id         = aws_subnet.public_a.id
  key_name          = var.key_name

  vpc_security_group_ids = [aws_security_group.mac.id]

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  tags = merge(local.tags, { Name = "${local.name}-instance" })
}

# --------------------------------------------------------------------------
# Provision the app via SSH
# --------------------------------------------------------------------------

resource "terraform_data" "provision" {
  depends_on = [aws_instance.mac]

  triggers_replace = [
    aws_instance.mac.id,
    filemd5("${path.module}/../Package.swift"),
    # every build input, not just *.swift: wtqrk-scan links its Info.plist (Vision needs it)
    md5(join("", [for f in fileset("${path.module}/../Sources", "**") : filemd5("${path.module}/../Sources/${f}")])),
    filemd5("${path.module}/../openapi.yaml"),
    filemd5("${path.module}/files/com.wtqrk.qrscanner.plist.tftpl"),
    filemd5("${path.module}/files/com.wtqrk.qrscanner-bootstrap.plist"),
    var.wtqrk_user,
    var.wtqrk_pass,
  ]

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file(var.private_key_path)
    host        = aws_instance.mac.public_ip
    timeout     = "15m"
  }

  provisioner "file" {
    source      = "${path.module}/../Sources"
    destination = "/Users/ec2-user/qr-scanner/Sources"
  }

  # Package.swift declares the test targets' paths; SwiftPM rejects the manifest if they're missing.
  provisioner "file" {
    source      = "${path.module}/../Tests"
    destination = "/Users/ec2-user/qr-scanner/Tests"
  }

  provisioner "file" {
    source      = "${path.module}/../Package.swift"
    destination = "/Users/ec2-user/qr-scanner/Package.swift"
  }

  provisioner "file" {
    source      = "${path.module}/../william_tells_qr_killer_trimmed.png"
    destination = "/Users/ec2-user/qr-scanner/william_tells_qr_killer_trimmed.png"
  }

  provisioner "file" {
    source      = "${path.module}/../openapi.yaml"
    destination = "/Users/ec2-user/qr-scanner/openapi.yaml"
  }

  provisioner "file" {
    content = templatefile("${path.module}/files/com.wtqrk.qrscanner.plist.tftpl", {
      app_port = var.app_port, wtqrk_user = var.wtqrk_user, wtqrk_pass = var.wtqrk_pass
    })
    destination = "/tmp/com.wtqrk.qrscanner.plist"
  }

  provisioner "file" {
    source      = "${path.module}/files/com.wtqrk.qrscanner-bootstrap.plist"
    destination = "/tmp/com.wtqrk.qrscanner-bootstrap.plist"
  }

  provisioner "remote-exec" {
    inline = [
      "sleep 30",
      "xcode-select -p || (xcode-select --install && sleep 120) || true",
      "cd /Users/ec2-user/qr-scanner && swift build -c release 2>&1",
      "sudo mkdir -p /var/log/wtqrk && sudo chown -R ec2-user /var/log/wtqrk",  # -R: the old root daemon left root-owned logs here
      # Earlier deploys ran the app as a root LaunchDaemon, where App Sandbox can't start the scanner.
      "sudo launchctl bootout system/com.wtqrk.qrscanner 2>/dev/null || true",
      "sudo rm -f /Library/LaunchDaemons/com.wtqrk.qrscanner.plist",
      "mkdir -p /Users/ec2-user/Library/LaunchAgents && mv /tmp/com.wtqrk.qrscanner.plist /Users/ec2-user/Library/LaunchAgents/",
      "sudo install -o root -g wheel -m 644 /tmp/com.wtqrk.qrscanner-bootstrap.plist /Library/LaunchDaemons/",
      "sudo launchctl bootout user/$(id -u)/com.wtqrk.qrscanner 2>/dev/null || true",
      "sudo launchctl bootstrap user/$(id -u) /Users/ec2-user/Library/LaunchAgents/com.wtqrk.qrscanner.plist",
      # The sandbox self-test (a real Vision scan) runs before /health is ready.
      "for i in $(seq 1 60); do curl -sf http://localhost:${var.app_port}/health && exit 0; sleep 2; done; echo 'Service not ready:'; curl -s http://localhost:${var.app_port}/health; tail -20 /var/log/wtqrk/stderr.log; exit 1",
    ]
  }
}

# --------------------------------------------------------------------------
# ALB
# --------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  tags               = local.tags
}

resource "aws_lb_target_group" "app" {
  name     = "${local.name}-tg"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    port                = tostring(var.app_port)
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  tags = local.tags
}

resource "aws_lb_target_group_attachment" "mac" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.mac.id
  port             = var.app_port
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.cert.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# --------------------------------------------------------------------------
# Route53 DNS
# --------------------------------------------------------------------------

resource "aws_route53_record" "app" {
  zone_id = var.hosted_zone_id
  name    = var.hostname
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
