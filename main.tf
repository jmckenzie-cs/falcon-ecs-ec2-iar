provider "aws" {
  region = var.region
  # Credentials are inherited from the environment (AWS_PROFILE, AWS_ACCESS_KEY_ID, etc.)
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Latest Amazon ECS-optimized Amazon Linux 2 AMI
data "aws_ami" "ecs_optimized" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*-x86_64-ebs"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  project_name = "jason-ecs-ec2-iar"

  # Use the first two available AZs in the region
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Carve subnets from the VPC CIDR:
  #   public:  .0.0/24, .1.0/24   → NAT GW and bastion (if needed)
  #   private: .10.0/24, .11.0/24 → ECS container instances (no inbound from internet)
  public_subnet_cidrs  = [for i in [0, 1] : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i in [10, 11] : cidrsubnet(var.vpc_cidr, 8, i)]
}
