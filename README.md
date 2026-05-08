# falcon-ecs-ec2-iar

Terraform environment for deploying **CrowdStrike Falcon Sensor** (host protection) and **Falcon Image Assessment at Runtime (IAR)** on an Amazon ECS cluster using the EC2 launch type.

Use this as a verified reference for understanding integration points, IAM requirements, credential handling, and deployment patterns before rolling out to production.

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

## Prerequisites

- Terraform >= 1.x
- AWS CLI configured with appropriate credentials
- GitHub CLI or Docker (for the IAR image mirror step)
- A CrowdStrike Falcon API client with the following scopes:
  - **Sensor Download (read)** — for Falcon Sensor install
  - **Falcon Images Download (read)** — for IAR image pull
  - **Sensor Download (read)** — for IAR image pull

---

## Usage

```bash
# 1. Clone the repo
git clone https://github.com/jmckenzie-cs/falcon-ecs-ec2-iar.git
cd falcon-ecs-ec2-iar

# 2. Configure credentials
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Falcon CID, client_id, and client_secret

# 3. Deploy
terraform init
terraform apply

# 4. Tear down
terraform destroy
```

---

## Falcon Sensor Deployment

The Falcon Sensor is installed directly on each EC2 container instance at boot via the Launch Template user data script. This is the correct pattern for ECS on EC2 — the sensor runs as a host-level agent (not a container), protecting the underlying OS and all processes on the instance.

On every new instance launch, the user data script:

1. Registers the instance with the ECS cluster
2. Installs prerequisites: `jq`, `curl`, `libnl`
3. Authenticates to the CrowdStrike API to obtain an OAuth2 bearer token
4. Queries `/sensors/combined/installers/v3` and filters for the Amazon Linux 2 x86_64 RPM
5. Downloads and installs the RPM
6. Configures the CID via `falconctl` and starts the `falcon-sensor` systemd service

### Key Implementation Notes

- **Sensor lookup filter**: `/sensors/combined/installers/v3` returns up to 100 results across all platforms. The jq filter `[.resources[] | select(.os_version == "2" and (.name | test("x86_64")))][0].sha256` is required to target the correct Amazon Linux 2 x86_64 RPM — using `resources[0]` without filtering returns incorrect results (e.g., VMware OVAs).
- **Download endpoint**: Use `/sensors/entities/download-installer/v2` (not `/sensors/entities/installers/v1`, which returns metadata JSON rather than the binary).
- **libnl dependency**: The Amazon Linux 2 sensor RPM requires `libnl`, which is not pre-installed on the ECS-optimized AMI and must be explicitly installed before the RPM.

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

IAR runs as an ECS **daemon service** (one task per container instance) in **Docker Socket Mode**. This ensures every container image launched on the cluster is scanned.

The IAR image is pulled from `registry.crowdstrike.com` during `terraform apply` and mirrored to Amazon ECR via the official CrowdStrike pull script (`falcon-container-sensor-pull.sh`). This removes the runtime dependency on the CrowdStrike registry and avoids configuring ECS task registry credentials.

> **Note:** The CrowdStrike registry uses a two-step auth flow — the raw OAuth2 bearer token cannot be used directly with `docker login`. The official pull script handles this correctly.

### ECS Task Configuration

| Setting | Value | Reason |
|---|---|---|
| Network mode | `bridge` | Required for Docker socket bind-mount on ECS EC2 |
| Scheduling strategy | `DAEMON` | One IAR task per container instance |
| Launch type | `EC2` | Host socket access not available on Fargate |
| Container user | `root` | Required for Docker socket access |
| Volume | `/var/run/docker.sock` host bind-mount | Socket mode operation |
| Linux capability | `SYS_ADMIN` | Required for socket access |
| Memory | 4096 MB hard / 256 MB soft | IAR uses ~2–4 GB per image scanned; soft reservation keeps scheduling overhead low |

### Resource Consumption

| State | CPU | Memory |
|---|---|---|
| Idle | ~0 | < 1 GB |
| Per image being assessed | moderate burst | ~2–4 GB |

The 4096 MB hard limit / 256 MB soft reservation gives IAR enough headroom to scan images without being OOM-killed. Monitor actual peak usage via CloudWatch Container Insights (enabled on this cluster) and adjust the hard limit for production.

---

## Credential Handling

All CrowdStrike credentials (`falcon_cid`, `falcon_client_id`, `falcon_client_secret`) are passed as Terraform variables declared `sensitive = true` and are never written to state in plain text.

For this test environment they are stored in `terraform.tfvars` — **this file must not be committed to source control** (it is gitignored).

For production, source credentials from AWS Secrets Manager, HashiCorp Vault, or CI/CD environment variables.

---

## Instance Refresh

When the Launch Template user data is updated (e.g., to change sensor install logic), existing instances must be replaced. The ASG is configured with `protect_from_scale_in = true` (required by ECS managed scaling), which causes rolling refreshes to stall unless protection is removed first.

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

Total time for a 2-instance cluster: ~10 minutes. If the refresh stalls mid-way, re-run the set-instance-protection command for the remaining old instance.

---

## Moving to Production

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

# View IAR scan results in Falcon Console
# Cloud Security → Image Assessment → Runtime
```
