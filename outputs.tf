output "ecr_image_url" {
  description = "ECR image URL used by the IAR task definition"
  value       = local.ecr_image_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "asg_name" {
  description = "Auto Scaling Group name for the ECS container instances"
  value       = aws_autoscaling_group.ecs.name
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (ECS container instances)"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (NAT GW)"
  value       = aws_subnet.public[*].id
}

output "iar_service_name" {
  description = "IAR daemon service name"
  value       = aws_ecs_service.iar.name
}

output "ssm_session_command" {
  description = "Example SSM command to connect to a container instance (fill in instance-id)"
  value       = "aws ssm start-session --target <instance-id> --region ${var.region}"
}

output "falcon_console_url" {
  description = "Falcon Console URL to view IAR results"
  value       = "https://falcon.laggar.gcw.crowdstrike.com/cloud-security/image-assessment/runtime"
}
