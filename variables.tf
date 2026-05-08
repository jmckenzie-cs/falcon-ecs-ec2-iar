variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (distinct from EKS 10.0.0.0/16)"
  type        = string
  default     = "10.1.0.0/16"
}

variable "instance_type" {
  description = "EC2 instance type for ECS container instances"
  type        = string
  default     = "t3.medium"
}

variable "desired_capacity" {
  description = "Desired number of EC2 container instances"
  type        = number
  default     = 2
}

variable "min_size" {
  description = "Minimum number of EC2 container instances"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of EC2 container instances"
  type        = number
  default     = 3
}

variable "falcon_cid" {
  description = "Falcon Customer ID (CID)"
  type        = string
  sensitive   = true
}

variable "falcon_client_id" {
  description = "Falcon API client ID for IAR"
  type        = string
  sensitive   = true
}

variable "falcon_client_secret" {
  description = "Falcon API client secret for IAR"
  type        = string
  sensitive   = true
}

variable "falcon_image_repo" {
  description = "IAR container image repository"
  type        = string
  default     = "registry.crowdstrike.com/falcon-imageanalyzer/us-2/release/falcon-imageanalyzer"
}

variable "falcon_image_tag" {
  description = "IAR container image tag"
  type        = string
  default     = "latest"
}

variable "falcon_region" {
  description = "CrowdStrike cloud region"
  type        = string
  default     = "us-2"
}
