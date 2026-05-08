data "aws_caller_identity" "current" {}

# ──────────────────────────────────────────────────────────────
# ECR repository for the IAR image
# Mirroring from registry.crowdstrike.com is the recommended
# approach (per CrowdStrike docs) to avoid runtime dependency
# on the external registry and its bearer-token auth.
# ──────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "iar" {
  name                 = "${local.project_name}/falcon-imageanalyzer"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  tags = {
    Name = "${local.project_name}-ecr"
  }
}

resource "aws_ecr_lifecycle_policy" "iar" {
  repository = aws_ecr_repository.iar.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 3 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 3
      }
      action = { type = "expire" }
    }]
  })
}

locals {
  # CrowdStrike API base URL varies by cloud region
  cs_api_base = var.falcon_region == "us-1" ? "https://api.crowdstrike.com" : "https://api.${var.falcon_region}.crowdstrike.com"

  # ECR registry hostname (account.dkr.ecr.region.amazonaws.com)
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"

  # Parent path passed to pull script --copy; the script appends /falcon-imageanalyzer
  # Result: <ecr_registry>/jason-ecs-ec2-iar/falcon-imageanalyzer:<tag>
  ecr_repo_prefix = "${local.ecr_registry}/${local.project_name}"

  # Full image URL used in the ECS task definition
  ecr_image_url = "${aws_ecr_repository.iar.repository_url}:${var.falcon_image_tag}"
}

# ──────────────────────────────────────────────────────────────
# Pull IAR from CrowdStrike registry → push to ECR
# Uses the official CrowdStrike pull script which handles the
# two-step auth (OAuth token → registry-specific credential).
# Runs locally during terraform apply.
# Prerequisites on Terraform host: docker, curl, aws CLI
# ──────────────────────────────────────────────────────────────

resource "null_resource" "pull_push_iar" {
  triggers = {
    ecr_repo  = aws_ecr_repository.iar.repository_url
    image_tag = var.falcon_image_tag
    cs_repo   = var.falcon_image_repo
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      echo "==> Logging into ECR..."
      aws ecr get-login-password --region ${var.region} | \
        docker login --username AWS --password-stdin ${local.ecr_registry}

      echo "==> Downloading CrowdStrike pull script..."
      curl -sSL -o /tmp/falcon-pull-iar.sh \
        "https://raw.githubusercontent.com/CrowdStrike/falcon-scripts/main/bash/containers/falcon-container-sensor-pull/falcon-container-sensor-pull.sh"
      chmod +x /tmp/falcon-pull-iar.sh

      echo "==> Pulling IAR and copying to ECR (this may take a few minutes)..."
      /tmp/falcon-pull-iar.sh \
        --client-id "${var.falcon_client_id}" \
        --client-secret "${var.falcon_client_secret}" \
        --type falcon-imageanalyzer \
        --region "${var.falcon_region}" \
        --copy "${local.ecr_repo_prefix}" \
        --copy-custom-tag "${var.falcon_image_tag}" \
        --platform x86_64

      echo "==> Done. Image available at: ${local.ecr_image_url}"
    EOT
  }

  depends_on = [aws_ecr_repository.iar]
}
