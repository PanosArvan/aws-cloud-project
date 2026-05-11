# =============================================================================
# Phase 1 — Load Balancer + 2x EC2 Web Servers
# AWS Academy Learner Lab
#
# Resources created:
#   - VPC with DNS enabled
#   - Internet Gateway
#   - 2x Public subnets (different AZs — required by ALB)
#   - Route table + associations
#   - Security group for ALB  (port 80 open to internet)
#   - Security group for EC2  (port 80 from ALB only, port 22 from your IP)
#   - 2x EC2 instances running Apache (Amazon Linux 2023, t2.micro)
#   - Application Load Balancer
#   - Target group + listener
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
#   terraform destroy   <-- run at end of every session to stop ALB charges
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

# -----------------------------------------------------------------------------
# Provider
# -----------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "my_ip" {
  description = "Your public IP in CIDR notation (e.g. 1.2.3.4/32) for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "project_name" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "project"
}

# -----------------------------------------------------------------------------
# Data sources
# -----------------------------------------------------------------------------

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

# -----------------------------------------------------------------------------
# Subnets
# -----------------------------------------------------------------------------

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-public-subnet-a"
    Project = var.project_name
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-public-subnet-b"
    Project = var.project_name
  }
}

# -----------------------------------------------------------------------------
# Route table
# -----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP inbound to the load balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
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

  tags = {
    Name    = "${var.project_name}-alb-sg"
    Project = var.project_name
  }
}

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "Allow HTTP from ALB and SSH from admin IP"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH from admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-ec2-sg"
    Project = var.project_name
  }
}

# -----------------------------------------------------------------------------
# EC2 Instances
# Each instance installs Apache and writes a styled HTML page showing
# its instance ID, hostname, AZ, and private IP.
# Refreshing the ALB URL alternates between the two instances.
# -----------------------------------------------------------------------------

locals {
  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd
    systemctl enable httpd
    systemctl start httpd
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    HOSTNAME_VAL=$(hostname -f)
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
    LOCAL_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
    cat > /var/www/html/index.html << HTMLEOF
    <!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>Cloud Project</title>
    <style>
    *{margin:0;padding:0;box-sizing:border-box}
    body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f0f4f8;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:2rem}
    .card{background:#fff;border-radius:12px;padding:2.5rem;max-width:520px;width:100%;border:1px solid #e2e8f0}
    .badge{display:inline-block;background:#dcfce7;color:#166534;font-size:12px;font-weight:600;padding:4px 12px;border-radius:20px;margin-bottom:1.2rem}
    h1{font-size:1.5rem;font-weight:700;color:#0f172a;margin-bottom:.4rem}
    .sub{font-size:.95rem;color:#64748b;margin-bottom:2rem}
    .divider{height:1px;background:#f1f5f9;margin:1.5rem 0}
    .row{display:flex;justify-content:space-between;align-items:center;gap:1rem;margin-bottom:1rem}
    .label{font-size:.85rem;color:#94a3b8;font-weight:500;text-transform:uppercase;letter-spacing:.05em;white-space:nowrap}
    .value{font-size:.92rem;color:#1e293b;font-family:monospace;text-align:right;word-break:break-all}
    .footer{margin-top:2rem;font-size:.8rem;color:#cbd5e1;text-align:center}
    </style></head><body>
    <div class="card">
    <div class="badge">HEALTHY</div>
    <h1>Cloud Project</h1>
    <p class="sub">AWS Academy Learner Lab &mdash; Phase 1</p>
    <div class="divider"></div>
    <div class="row"><span class="label">Instance ID</span><span class="value">$INSTANCE_ID</span></div>
    <div class="row"><span class="label">Hostname</span><span class="value">$HOSTNAME_VAL</span></div>
    <div class="row"><span class="label">Availability Zone</span><span class="value">$AZ</span></div>
    <div class="row"><span class="label">Private IP</span><span class="value">$LOCAL_IP</span></div>
    <div class="footer">Load Balancer + 2x EC2 &mdash; Refresh to see the other instance</div>
    </div></body></html>
    HTMLEOF
  EOF
}

resource "aws_instance" "web" {
  count = 2

  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = count.index == 0 ? aws_subnet.public_a.id : aws_subnet.public_b.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  user_data              = local.user_data

  # key_name = "your-keypair-name"

  tags = {
    Name    = "${var.project_name}-web-server-${count.index + 1}"
    Project = var.project_name
    Role    = "web"
  }
}

# -----------------------------------------------------------------------------
# Application Load Balancer
# -----------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  enable_deletion_protection = false

  tags = {
    Name    = "${var.project_name}-alb"
    Project = var.project_name
  }
}

resource "aws_lb_target_group" "web" {
  name     = "${var.project_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name    = "${var.project_name}-tg"
    Project = var.project_name
  }
}

resource "aws_lb_target_group_attachment" "web" {
  count            = 2
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web[count.index].id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "alb_dns_name" {
  description = "Open this URL in your browser to test the load balancer"
  value       = "http://${aws_lb.main.dns_name}"
}

output "instance_ids" {
  description = "EC2 instance IDs"
  value       = aws_instance.web[*].id
}

output "instance_public_ips" {
  description = "Public IPs of EC2 instances"
  value       = aws_instance.web[*].public_ip
}

# =============================================================================
# Phase 2 — Cloud Governance
# CloudWatch dashboard, alarms, and SNS email notifications
# =============================================================================

# -----------------------------------------------------------------------------
# Variable — alert email
# -----------------------------------------------------------------------------

variable "alert_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
  default     = "panagiotisarvanitakis@gmail.com"
}

# -----------------------------------------------------------------------------
# SNS Topic + Email Subscription
# After terraform apply, check your email and confirm the subscription —
# you will not receive alerts until you click the confirmation link.
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"

  tags = {
    Name    = "${var.project_name}-alerts"
    Project = var.project_name
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# -----------------------------------------------------------------------------
# CloudWatch Alarms — CPU utilisation per EC2 instance
# Triggers when CPU exceeds 70% for two consecutive 1-minute periods.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  count = 2

  alarm_name          = "${var.project_name}-cpu-high-web-${count.index + 1}"
  alarm_description   = "CPU utilisation above 70% on web-server-${count.index + 1}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 70

  dimensions = {
    InstanceId = aws_instance.web[count.index].id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name    = "${var.project_name}-cpu-alarm-${count.index + 1}"
    Project = var.project_name
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Dashboard
# Displays EC2 CPU, ALB request count, healthy host count, and network traffic.
# View it in: AWS Console → CloudWatch → Dashboards → project-dashboard
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "## Cloud Project — Phase 2 Monitoring Dashboard"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 12
        height = 6
        properties = {
          title  = "EC2 CPU Utilisation — Web Server 1"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.web[0].id,
            { label = "Web Server 1 CPU", color = "#2E75B6" }]
          ]
          yAxis = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [{ value = 70, label = "Alarm threshold (70%)", color = "#d62728" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 1
        width  = 12
        height = 6
        properties = {
          title  = "EC2 CPU Utilisation — Web Server 2"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.web[1].id,
            { label = "Web Server 2 CPU", color = "#1F9E75" }]
          ]
          yAxis = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [{ value = 70, label = "Alarm threshold (70%)", color = "#d62728" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 8
        height = 6
        properties = {
          title  = "ALB — Request Count"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix,
            { label = "Total Requests", stat = "Sum", color = "#9467bd" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 7
        width  = 8
        height = 6
        properties = {
          title  = "ALB — Healthy Host Count"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount",
              "TargetGroup", aws_lb_target_group.web.arn_suffix,
              "LoadBalancer", aws_lb.main.arn_suffix,
            { label = "Healthy Hosts", stat = "Average", color = "#2ca02c" }]
          ]
          yAxis = { left = { min = 0, max = 3 } }
          annotations = {
            horizontal = [{ value = 2, label = "Expected (2 healthy)", color = "#2ca02c" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 7
        width  = 8
        height = 6
        properties = {
          title  = "EC2 Network Traffic (Both Instances)"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.web[0].id, { label = "WS1 In", color = "#2E75B6" }],
            ["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.web[0].id, { label = "WS1 Out", color = "#aec7e8" }],
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.web[1].id, { label = "WS2 In", color = "#1F9E75" }],
            ["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.web[1].id, { label = "WS2 Out", color = "#98df8a" }]
          ]
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Additional outputs for Phase 2
# -----------------------------------------------------------------------------

output "cloudwatch_dashboard_url" {
  description = "Direct link to the CloudWatch dashboard in the AWS Console"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${var.project_name}-dashboard"
}

output "sns_topic_arn" {
  description = "SNS topic ARN — alarm notifications are sent here"
  value       = aws_sns_topic.alerts.arn
}