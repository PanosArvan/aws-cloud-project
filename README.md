# Phase 1 — AWS Infrastructure
## Load Balancer + 2x EC2 Web Servers

This Terraform configuration deploys the Phase 1 architecture for the cloud project:
an Application Load Balancer distributing HTTP traffic across two Apache web servers
running on EC2 instances inside a custom VPC.

---

## Architecture overview

```
Internet
    │
    ▼
Application Load Balancer  (public, port 80)
    │               │
    ▼               ▼
EC2 web-1       EC2 web-2
(Apache)        (Apache)
us-east-1a      us-east-1b
```

All resources live inside a dedicated VPC (`10.0.0.0/16`) with two public subnets
in separate availability zones. EC2 instances only accept HTTP traffic from the ALB —
not directly from the internet.

---

## Prerequisites

Install the following before running anything:

| Tool | Version | Install |
|------|---------|---------|
| Terraform | ≥ 1.3 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | ≥ 2.x | https://aws.amazon.com/cli/ |
| VS Code (optional) | any | https://code.visualstudio.com |
| HashiCorp Terraform extension (optional) | any | VS Code Extensions panel |

Verify both tools are installed:

```bash
terraform -version
aws --version
```

---

## AWS Academy Learner Lab — credential setup

The Learner Lab issues temporary credentials that expire when your session ends.
**You must refresh these at the start of every session.**

1. In the Learner Lab panel, click **AWS Details → AWS CLI**
2. Copy the entire credentials block
3. Paste it into your credentials file, replacing the previous contents:

**Windows:**
```
C:\Users\<your-username>\.aws\credentials
```

**macOS / Linux:**
```
~/.aws/credentials
```

The file must look exactly like this (all three lines are required):

```ini
[default]
aws_access_key_id     = ASIA...
aws_secret_access_key = ...
aws_session_token     = ...
```

> **Note:** The `aws_session_token` line is mandatory for the Learner Lab.
> Without it, all AWS API calls will fail with an authentication error.

---

## Deploying the infrastructure

### First time only

```bash
# Clone or download this project, then open its folder
cd cloud-project

# Download the AWS Terraform provider (~50 MB, one-time)
terraform init
```

### Every session

```bash
# 1. Refresh your AWS credentials (see above)

# 2. Preview what will be created — no changes made yet
terraform plan

# 3. Deploy everything (takes ~3 minutes)
terraform apply
# Type "yes" when prompted

# 4. The ALB URL is printed at the end:
#    alb_dns_name = "http://project-alb-xxxx.us-east-1.elb.amazonaws.com"
#    Open it in your browser to verify
```

### Tearing down (end of every session)

```bash
terraform destroy
# Type "yes" when prompted
```

> **Important:** Always run `terraform destroy` at the end of each session.
> The Application Load Balancer charges by the hour even when idle.
> EC2 instances stop automatically, but the ALB does not.

---

## Validating the deployment

After `terraform apply` completes:

1. Copy the `alb_dns_name` URL from the terminal output
2. Open it in a browser — you should see: `Hello from ip-10-0-x-x.ec2.internal`
3. Refresh several times — the hostname should alternate between two different values
4. This confirms the load balancer is distributing traffic across both instances

You can also check the AWS Console:
- **EC2 → Load Balancers** — status should be `Active`
- **EC2 → Target Groups → project-tg → Targets** — both instances should show `Healthy`

---

## Configuration

Variables can be overridden without editing `main.tf`.
Create a file called `terraform.tfvars` in the same folder:

```hcl
# terraform.tfvars
aws_region    = "us-east-1"
instance_type = "t2.micro"
project_name  = "project"
my_ip         = "YOUR.PUBLIC.IP.HERE/32"  # restricts SSH to your machine only
```

> `terraform.tfvars` is in `.gitignore` — never commit it, as it may contain your IP.

To find your public IP:
```bash
curl https://checkip.amazonaws.com
```

---

## Resources created

| Resource | Name | Notes |
|----------|------|-------|
| VPC | project-vpc | 10.0.0.0/16 |
| Internet Gateway | project-igw | Attached to VPC |
| Subnet A | project-public-subnet-a | 10.0.1.0/24, us-east-1a |
| Subnet B | project-public-subnet-b | 10.0.2.0/24, us-east-1b |
| Route table | project-public-rt | Routes 0.0.0.0/0 → IGW |
| Security group | project-alb-sg | Port 80 open to internet |
| Security group | project-ec2-sg | Port 80 from ALB only, port 22 from admin IP |
| EC2 instance | project-web-server-1 | Amazon Linux 2023, t2.micro, Apache |
| EC2 instance | project-web-server-2 | Amazon Linux 2023, t2.micro, Apache |
| Application Load Balancer | project-alb | Internet-facing, port 80 |
| Target group | project-tg | Health check on / |
| ALB Listener | — | Forwards port 80 → target group |

---

## SSH access (optional)

SSH is not required for the project but can be useful for debugging.

1. Create a key pair in the AWS Console: **EC2 → Key Pairs → Create**
2. Download the `.pem` file
3. Uncomment the `key_name` line in `main.tf` and set it to your key pair name
4. Re-run `terraform apply`

```bash
# macOS / Linux
chmod 400 your-key.pem
ssh -i your-key.pem ec2-user@<instance-public-ip>

# Windows (using OpenSSH in PowerShell)
ssh -i your-key.pem ec2-user@<instance-public-ip>
```

Instance public IPs are printed by `terraform apply` as `instance_public_ips`.

---

## Estimated cost

| Resource | Approx. hourly cost |
|----------|-------------------|
| 2x t2.micro EC2 | ~$0.02/hr (or free tier) |
| Application Load Balancer | ~$0.02/hr + data |
| VPC / subnets / IGW | Free |

Running for a 4-hour session costs roughly **$0.20–$0.40**.
Always `terraform destroy` at session end.

---

## File structure

```
cloud-project/
├── main.tf              # All infrastructure code
├── terraform.tfvars     # Your variable overrides (gitignored)
├── .gitignore           # Excludes state files and secrets
├── README.md            # This file
└── .terraform/          # Provider downloads (gitignored, auto-generated)
```

---

## Troubleshooting

**`Error: No valid credential sources found`**
→ Your AWS credentials are missing or expired. Repeat the credential setup step.

**`Error: error creating LB: ValidationError: At least two subnets in two different AZs`**
→ The region you set doesn't have `us-east-1a` and `us-east-1b`. Change `aws_region` in `terraform.tfvars` or check which AZs are available in your Learner Lab.

**ALB URL returns 502 Bad Gateway**
→ Apache is still starting on the EC2 instances. Wait 1–2 minutes and refresh.
→ Check target health in **EC2 → Target Groups → project-tg → Targets**.

**`terraform destroy` fails partway through**
→ Run it again — Terraform is safe to re-run and will pick up where it left off.
