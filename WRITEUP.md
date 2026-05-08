# CrowdStrike on ECS (EC2 Launch Type) — Test Environment Write-Up

## Overview

This document describes a Terraform-based test environment that deploys an Amazon ECS cluster on EC2 container instances with two CrowdStrike security components: the **Falcon Sensor for Linux** (host protection) and the **Falcon Image Assessment at Runtime (IAR)** agent (container image scanning). The goal is to validate both deployments in a controlled environment that mirrors the structural patterns of a production deployment.

A customer can use this environment as a verified reference to understand integration points, IAM requirements, credential handling, and deployment patterns before rolling out to production.

---

## Architecture

```
AWS Account (us-east-1)
└── VPC: 10.1.0.0/16
    ├── Public Subnets (10.1.0.0/24, 10.1.1.0/24) — AZ a/b
    │   └── NAT Gateway (single, shared)
    └── Private Subnets (10.1.10.0/24, 10.1.11.0/24) — AZ a/b
        └── ECS Container Instances (t3.medium × 2)
            ├── ECS Agent → cluster: jason-ecs-ec2-iar
            ├── Falcon Sensor (host agent)
            └── Docker containers:
                ├── falcon-imageanalyzer (DAEMON — 1 per instance)
                └── nginx test workload (REPLICA — 1 total)
```

All EC2 instances run in private subnets with no inbound access. Outbound traffic routes through the NAT Gateway for CrowdStrike cloud connectivity and ECR image pulls.

---

## Infrastructure Components

| Resource | Description |
|---|---|
| VPC + subnets | Isolated network with public/private subnets across 2 AZs |
| NAT Gateway | Single shared NAT for private subnet egress |
| ECS Cluster | `jason-ecs-ec2-iar` with Container Insights enabled |
| Launch Template | ECS-optimized Amazon Linux 2 AMI; user data installs Falcon sensor |
| Auto Scaling Group | desired: 2, min: 1, max: 3 — with rolling instance refresh |
| ECS Capacity Provider | Managed scaling linked to the ASG |
| ECR Repository | Hosts the mirrored IAR image (`falcon-imageanalyzer:latest`) |
| IAM Roles | EC2 instance role, ECS task execution role, IAR task role |

---

## Falcon Sensor Deployment

### Approach

The Falcon Sensor for Linux is installed directly on each EC2 container instance at boot via the **Launch Template user data** script. This is the correct pattern for ECS on EC2: the sensor runs as a host-level agent (not a container), providing protection for the underlying OS and all processes on the instance.

### How It Works

On every new instance launch, the user data script:

1. Registers the instance with the ECS cluster (`ECS_CLUSTER` written to `/etc/ecs/ecs.config`)
2. Installs prerequisites: `jq`, `curl`, `libnl` (required dependency for the sensor RPM)
3. Authenticates to the CrowdStrike API using the Falcon `client_id` and `client_secret` to obtain an OAuth2 bearer token
4. Queries `/sensors/combined/installers/v3` and filters for the Amazon Linux 2 x86_64 RPM specifically (using a jq filter on `os_version == "2"` and filename containing `x86_64`)
5. Downloads the RPM via `/sensors/entities/download-installer/v2` using the installer SHA256 as the ID
6. Installs the RPM with `rpm -ivh`
7. Configures the CID via `falconctl -s --cid=<CID>`
8. Enables and starts the `falcon-sensor` systemd service

The install is wrapped in a subshell so any failure is logged to `/var/log/falcon-install.log` without blocking ECS cluster registration.

### Key Implementation Notes

- **Sensor lookup filter**: The `/sensors/combined/installers/v3` endpoint returns up to 100 results across all platforms and architectures. The jq filter `[.resources[] | select(.os_version == "2" and (.name | test("x86_64")))][0].sha256` is required to target the correct Amazon Linux 2 x86_64 RPM. Using `resources[0]` without filtering returns incorrect results (e.g., VMware OVAs).
- **Download endpoint**: Use `/sensors/entities/download-installer/v2` (not `/sensors/entities/installers/v1`, which returns metadata JSON rather than the binary file).
- **libnl dependency**: The Amazon Linux 2 sensor RPM requires `libnl`, which is not pre-installed on the ECS-optimized AMI. It must be explicitly installed before the RPM.

### API Scopes Required

The Falcon API client used for sensor download needs:
- **Sensor Download (read)**

### Confirmed Running

Both EC2 container instances have the Falcon sensor active and registered:

| Instance | Service Status | AID |
|---|---|---|
| `i-070909a1ccfd71fca` | active | `0b2cd9ba82fd44b2910a3e640557d998` |
| `i-0cae986122b024bc9` | active | `7e8bc904a9d4472293f27c34db018885` |

### Verification

```bash
# SSM into an instance
aws ssm start-session --target <instance-id> --region us-east-1

# On the instance
sudo /opt/CrowdStrike/falconctl -g --aid   # non-empty AID = registered
systemctl status falcon-sensor             # should be active (running)
cat /var/log/falcon-install.log            # install output
```

---

## IAR Deployment

### Approach

IAR (Image Assessment at Runtime) runs in **Docker Socket Mode** as an ECS **daemon service** — one task per container instance. This ensures every EC2 instance has an IAR agent monitoring its local Docker socket, so every container image launched anywhere in the cluster is scanned.

The IAR image is pulled from the CrowdStrike registry during `terraform apply` and mirrored to **Amazon ECR**. This removes the runtime dependency on `registry.crowdstrike.com` and avoids the need to configure ECS task registry credentials.

### Image Mirroring (CrowdStrike Registry → ECR)

The official CrowdStrike FCS pull script (`falcon-container-sensor-pull.sh`) handles the two-step authentication to `registry.crowdstrike.com`:
1. Exchange `client_id`/`client_secret` for an OAuth2 bearer token
2. Exchange the bearer token for a registry-specific credential
3. Pull the image and copy it to ECR using the `--copy` flag

This runs as a Terraform `null_resource` local-exec provisioner during apply, so the ECR repo is always populated before the ECS task definition is created.

> **Note:** The CrowdStrike registry uses a two-step auth flow — the raw OAuth2 bearer token cannot be used directly with `docker login`. The official pull script handles this correctly. Attempting to authenticate manually with the bearer token will result in an HTTP 500 from the registry.

> **Note:** Re-runs of `terraform apply` will only re-push the image if the ECR repo URL or image tag changes (controlled by the `null_resource` triggers).

### ECS Task Configuration

| Setting | Value | Reason |
|---|---|---|
| Network mode | `bridge` | Required for Docker socket bind-mount on ECS EC2 |
| Scheduling strategy | `DAEMON` | One IAR task per container instance |
| Launch type | `EC2` | Host socket access not available on Fargate |
| Container user | `root` | Required for Docker socket access |
| Volume | `/var/run/docker.sock` host bind-mount | Socket mode operation |
| Linux capability | `SYS_ADMIN` | Required for socket access |
| Memory | 4096 MB hard / 256 MB soft | Hard limit prevents OOM-kill during image assessment (IAR uses ~2–4 GB per image scanned); soft reservation keeps scheduling overhead low |

### IAR Arguments

```
-cid        <Falcon CID>
-region     us-2
-runtime    docker
-runmode    socket
-socketpath unix:///run/docker.sock
```

### API Scopes Required

The Falcon API client used for IAR needs:
- **Falcon Images Download (read)**
- **Sensor Download (read)**

### Resource Consumption

Per CrowdStrike documentation, IAR resource usage depends on the number of images being processed at any given time:

| State | CPU | Memory |
|---|---|---|
| Idle | ~0 | < 1 GB |
| Per image being assessed | moderate burst | ~2–4 GB |

Key factors that increase consumption:
- **Number of running images** — more images means more concurrent memory usage
- **Number of image layers** — more layers means more memory for parsing (max layer size is 10 GB)
- **Socket mode** (used here) requires more compute than Watcher mode because it runs as a DaemonSet on every node

The 4096 MB hard limit / 256 MB soft reservation configured in this environment gives IAR enough headroom to scan images without being OOM-killed. The soft reservation keeps the ECS scheduler from over-reserving capacity on the instance — IAR sits at < 1 GB at idle and only bursts to 2–4 GB during active assessment. In production, monitor actual peak usage and adjust the hard limit accordingly. CrowdStrike does not publish a fixed minimum/maximum recommendation due to environment variability.

To observe real-time IAR resource usage on this cluster, use CloudWatch Container Insights (enabled on this cluster) or query the ECS task stats directly:

```bash
# Get IAR task IDs
aws ecs list-tasks --cluster jason-ecs-ec2-iar \
  --service-name jason-ecs-ec2-iar-service --region us-east-1

# Check task CPU/memory stats
aws ecs describe-tasks --cluster jason-ecs-ec2-iar \
  --tasks <task-id> --region us-east-1 \
  --query 'tasks[0].containers[0].{cpu:cpu,memory:memory,memoryReservation:memoryReservation}'
```

### Test Workload

A single nginx replica service (`jason-ecs-ec2-iar-test-svc`) is deployed alongside IAR to give it something to scan. When this container launches, IAR detects it via the Docker socket and submits the image for assessment. Results appear in the Falcon Console under **Cloud Security → Image Assessment → Runtime**.

---

## Credential Handling

All CrowdStrike credentials (`falcon_cid`, `falcon_client_id`, `falcon_client_secret`) are passed as Terraform variables and declared `sensitive = true`. They are never written to state in plain text. For this test environment they are stored in `terraform.tfvars` — **this file must not be committed to source control.**

For production, credentials should be sourced from a secrets manager (AWS Secrets Manager, HashiCorp Vault, or CI/CD environment variables) rather than a static tfvars file.

---

## Instance Refresh and Scale-In Protection

When the Launch Template user data is updated (e.g., to change the sensor install logic), existing instances must be replaced to pick up the new script. The ASG is configured with `protect_from_scale_in = true` (required by ECS managed scaling), which causes rolling instance refreshes to stall waiting for protection to be removed.

To trigger a rolling replacement after a launch template change:

```bash
# Remove scale-in protection from existing instances
aws autoscaling set-instance-protection \
  --auto-scaling-group-name jason-ecs-ec2-iar-asg \
  --instance-ids <instance-id-1> <instance-id-2> \
  --no-protected-from-scale-in \
  --region us-east-1

# Start instance refresh
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name jason-ecs-ec2-iar-asg \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":300}' \
  --region us-east-1
```

The refresh replaces one instance at a time (50% min healthy), waiting 5 minutes per instance for the warmup period. Total time for a 2-instance cluster: ~10 minutes. If the refresh stalls again mid-way, re-run the set-instance-protection command for the remaining old instance.

---

## Moving to Production

The test environment is intentionally close to a production pattern. Key differences to address before production deployment:

| Area | Test | Production Recommendation |
|---|---|---|
| **Credential storage** | `terraform.tfvars` on disk | AWS Secrets Manager or Vault; inject via CI/CD |
| **Terraform state** | Local (`terraform.tfstate`) | Remote backend (S3 + DynamoDB locking) |
| **Instance type** | `t3.medium` | Size based on container density and sensor overhead |
| **Sensor scope** | All instances in one ASG | Per-ASG user data; consider SSM Distributor for existing fleets |
| **IAR image** | `latest` tag | Pin to a specific version tag for reproducibility |
| **ECR** | Single region | Enable replication if multi-region |
| **Networking** | Single NAT GW | NAT GW per AZ for high availability |
| **Monitoring** | Container Insights (basic) | CloudWatch Dashboard + alarms on IAR CPU/memory |
| **IAM** | Broad test policies | Scope down to least-privilege; use IAM conditions |

---

## Quick Reference

```bash
# Check IAR daemon service health
aws ecs describe-services \
  --cluster jason-ecs-ec2-iar \
  --services jason-ecs-ec2-iar-service \
  --query 'services[0].{running:runningCount,desired:desiredCount}'

# Check Falcon sensor on an instance (via SSM)
aws ssm send-command \
  --instance-ids <instance-id> \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["systemctl is-active falcon-sensor","sudo /opt/CrowdStrike/falconctl -g --aid"]}' \
  --region us-east-1

# View IAR scan results
# https://falcon.laggar.gcw.crowdstrike.com/cloud-security/image-assessment/runtime

# Tear down all resources
terraform destroy
```
