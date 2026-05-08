# ──────────────────────────────────────────────────────────────
# EC2 Instance Role
# Assumed by EC2 instances; allows them to register with ECS
# ──────────────────────────────────────────────────────────────

resource "aws_iam_role" "instance" {
  name = "${local.project_name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "instance_ecs" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.project_name}-instance-profile"
  role = aws_iam_role.instance.name
}

# ──────────────────────────────────────────────────────────────
# ECS Task Execution Role
# Used by the ECS agent to pull images and write logs
# ──────────────────────────────────────────────────────────────

resource "aws_iam_role" "exec" {
  name = "${local.project_name}-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "exec_policy" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ──────────────────────────────────────────────────────────────
# IAR Task Role
# Assumed by the IAR container task itself. Credentials for
# the Falcon API are passed as environment variables, so no
# additional IAM policies are needed here.
# ──────────────────────────────────────────────────────────────

resource "aws_iam_role" "iar_task" {
  name = "${local.project_name}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
