# ──────────────────────────────────────────────────────────────
# Security Group for ECS container instances
# Allow all outbound; no inbound (instances are in private subnets)
# ──────────────────────────────────────────────────────────────

resource "aws_security_group" "instance" {
  name        = "${local.project_name}-instance-sg"
  description = "ECS container instance SG - outbound only"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.project_name}-instance-sg"
  }
}

# ──────────────────────────────────────────────────────────────
# ECS Cluster
# ──────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = local.project_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = local.project_name
  }
}

# ──────────────────────────────────────────────────────────────
# Launch Template for ECS container instances
# ──────────────────────────────────────────────────────────────

resource "aws_launch_template" "ecs" {
  name        = "${local.project_name}-lt"
  image_id    = data.aws_ami.ecs_optimized.id
  instance_type = var.instance_type

  user_data = base64encode(<<-EOF
    #!/bin/bash

    # ── ECS registration (must happen first) ──────────────────────
    echo ECS_CLUSTER=${local.project_name} >> /etc/ecs/ecs.config

    # ── Falcon sensor install ──────────────────────────────────────
    # Errors are logged but non-fatal so ECS registration is unaffected
    {
      set -e

      yum install -y jq curl libnl

      BEARER=$(curl -sf -X POST \
        "${local.cs_api_base}/oauth2/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${var.falcon_client_id}&client_secret=${var.falcon_client_secret}" \
        | jq -r '.access_token')

      [ -z "$BEARER" ] || [ "$BEARER" = "null" ] && { echo "ERROR: no bearer token"; exit 1; }

      SHA256=$(curl -sf \
        "${local.cs_api_base}/sensors/combined/installers/v1?platform=linux&os=Amazon+Linux" \
        -H "Authorization: Bearer $BEARER" \
        | jq -r '[.resources[] | select(.os_version == "2" and (.name | test("x86_64")))][0].sha256')

      [ -z "$SHA256" ] || [ "$SHA256" = "null" ] && { echo "ERROR: no sensor SHA256"; exit 1; }

      curl -sf -L -o /tmp/falcon-sensor.rpm \
        "${local.cs_api_base}/sensors/entities/download-installer/v2?id=$SHA256" \
        -H "Authorization: Bearer $BEARER"

      rpm -ivh /tmp/falcon-sensor.rpm

      /opt/CrowdStrike/falconctl -s --cid="${var.falcon_cid}"
      systemctl enable --now falcon-sensor

      echo "Falcon sensor installed and started successfully"
    } >> /var/log/falcon-install.log 2>&1
  EOF
  )

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.instance.id]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.project_name}-instance"
    }
  }
}

# ──────────────────────────────────────────────────────────────
# Auto Scaling Group
# ──────────────────────────────────────────────────────────────

resource "aws_autoscaling_group" "ecs" {
  name                = "${local.project_name}-asg"
  vpc_zone_identifier = aws_subnet.private[*].id
  desired_capacity    = var.desired_capacity
  min_size            = var.min_size
  max_size            = var.max_size

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  # Required for ECS managed scaling
  protect_from_scale_in = true

  tag {
    key                 = "Name"
    value               = "${local.project_name}-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }
}

# ──────────────────────────────────────────────────────────────
# ECS Capacity Provider
# ──────────────────────────────────────────────────────────────

resource "aws_ecs_capacity_provider" "main" {
  name = "${local.project_name}-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      maximum_scaling_step_size = 2
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 80
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.main.name]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = aws_ecs_capacity_provider.main.name
  }
}

# ──────────────────────────────────────────────────────────────
# IAR Task Definition (daemon — one per container instance)
# Docker socket mode: bind-mount /var/run/docker.sock
# ──────────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "iar" {
  family                = "${local.project_name}-task"
  network_mode          = "bridge"
  requires_compatibilities = ["EC2"]
  task_role_arn         = aws_iam_role.iar_task.arn
  execution_role_arn    = aws_iam_role.exec.arn

  volume {
    name = "docker-socket"

    host_path = "/var/run/docker.sock"
  }

  container_definitions = jsonencode([
    {
      name              = "falcon-imageanalyzer"
      image             = local.ecr_image_url
      essential         = true
      user              = "root"
      memory            = 4096
      memoryReservation = 256

      command = [
        "-cid",        var.falcon_cid,
        "-region",     var.falcon_region,
        "-runtime",    "docker",
        "-runmode",    "socket",
        "-socketpath", "unix:///run/docker.sock"
      ]

      environment = [
        {
          name  = "AGENT_CLIENT_ID"
          value = var.falcon_client_id
        },
        {
          name  = "AGENT_CLIENT_SECRET"
          value = var.falcon_client_secret
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "docker-socket"
          containerPath = "/var/run/docker.sock"
          readOnly      = false
        }
      ]

      linuxParameters = {
        capabilities = {
          add  = ["SYS_ADMIN"]
          drop = []
        }
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${local.project_name}/iar"
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "iar"
          "awslogs-create-group"  = "true"
        }
      }
    }
  ])

  tags = {
    Name = "${local.project_name}-task"
  }
}

# ──────────────────────────────────────────────────────────────
# IAR Daemon Service
# DAEMON scheduling ensures one IAR task runs on every EC2 instance
# ──────────────────────────────────────────────────────────────

resource "aws_ecs_service" "iar" {
  name                               = "${local.project_name}-service"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.iar.arn
  scheduling_strategy                = "DAEMON"
  launch_type                        = "EC2"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_iam_role_policy_attachment.exec_policy,
  ]

  tags = {
    Name = "${local.project_name}-service"
  }
}

# ──────────────────────────────────────────────────────────────
# Test Workload Task Definition
# A simple nginx container to verify IAR picks up new images
# ──────────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "workload" {
  family                = "${local.project_name}-workload"
  network_mode          = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn    = aws_iam_role.exec.arn

  container_definitions = jsonencode([
    {
      name              = "nginx"
      image             = "public.ecr.aws/nginx/nginx:latest"
      essential         = true
      memory            = 256
      memoryReservation = 128

      portMappings = [
        {
          containerPort = 80
          hostPort      = 0
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${local.project_name}/workload"
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "workload"
          "awslogs-create-group"  = "true"
        }
      }
    }
  ])

  tags = {
    Name = "${local.project_name}-workload"
  }
}

# ──────────────────────────────────────────────────────────────
# Test Workload Service (replica)
# ──────────────────────────────────────────────────────────────

resource "aws_ecs_service" "workload" {
  name            = "${local.project_name}-test-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.workload.arn
  desired_count = 1

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_ecs_service.iar,
  ]

  tags = {
    Name = "${local.project_name}-test-svc"
  }
}
