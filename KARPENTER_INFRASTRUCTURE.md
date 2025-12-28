# Karpenter Infrastructure Rationale

## Overview

This document explains the infrastructure setup for Karpenter 0.37.2 on AWS EKS. Karpenter is a flexible, high-performance Kubernetes cluster autoscaler that provisions right-sized compute resources in response to changing application load.

### Architecture Philosophy

**Key Design Principle**: Terraform manages infrastructure, Helm manages application installation.

- **Terraform scope**: IAM roles, OIDC provider, SQS queues, EventBridge rules, tags
- **Helm scope**: Karpenter controller installation and configuration
- **Separation rationale**: Decouples infrastructure lifecycle from application lifecycle, enabling independent upgrades

### Node Strategy

- **1 Managed Node (tainted)**: Runs system components (CoreDNS, Karpenter, metrics-server)
- **Karpenter-Provisioned Nodes**: Handle application workloads dynamically
- **Cost impact**: Reduces fixed costs from $61/month (2 nodes) to $30/month (1 node), with application nodes provisioned on-demand

---

## 1. OIDC Provider (karpenter.tf:1-28)

### Code

```hcl
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name        = "${var.cluster_name}-eks-oidc"
    Environment = "learning"
  }
}
```

### Rationale

**Purpose**: Enables IRSA (IAM Roles for Service Accounts), allowing Kubernetes service accounts to assume AWS IAM roles.

**Why OIDC?**
- Eliminates need to store AWS credentials in cluster
- Kubernetes service accounts become trusted identities in AWS
- Temporary credentials automatically rotated by AWS STS

**Why fetch TLS certificate?**
- AWS requires OIDC provider thumbprint for trust verification
- `data.tls_certificate` automatically retrieves the correct thumbprint from EKS cluster's OIDC issuer URL

**Security benefit**: Karpenter controller runs with least-privilege AWS permissions without storing access keys.

---

## 2. Karpenter Controller IAM Role (karpenter.tf:30-82)

### Code

```hcl
resource "aws_iam_role" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" : "system:serviceaccount:karpenter:karpenter"
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}
```

### Rationale

**Assume role policy**: Restricts role assumption to:
- The specific OIDC provider (Federated principal)
- Only the `karpenter` service account in `karpenter` namespace
- Only for audience `sts.amazonaws.com`

**Security principle**: Even if an attacker compromises a different service account, they cannot assume this role due to namespace/name restrictions.

---

## 3. Karpenter Controller IAM Policy (karpenter.tf:84-374)

### 3.1 EC2 Instance Management (Lines 95-149)

```hcl
statement {
  sid = "AllowScopedEC2InstanceActions"
  actions = [
    "ec2:RunInstances",
    "ec2:CreateFleet",
  ]
  resources = [
    "arn:aws:ec2:${data.aws_region.current.name}::image/*",
    "arn:aws:ec2:${data.aws_region.current.name}::snapshot/*",
    "arn:aws:ec2:${data.aws_region.current.name}:*:spot-instances-request/*",
    "arn:aws:ec2:${data.aws_region.current.name}:*:security-group/*",
    "arn:aws:ec2:${data.aws_region.current.name}:*:subnet/*",
    "arn:aws:ec2:${data.aws_region.current.name}:*:launch-template/*",
  ]
}
```

**Rationale**: Grants Karpenter permission to launch EC2 instances with specific resources:
- **AMIs and snapshots**: Required to boot instances
- **Spot requests**: Enables cost-saving spot instances
- **Security groups/subnets**: Must be specified during instance launch
- **Launch templates**: Karpenter creates ephemeral launch templates for each node

**Scoping**: Restricted to specific region and resource types, not account-wide `*` permissions.

### 3.2 Instance Tagging (Lines 151-163)

```hcl
statement {
  sid = "AllowScopedEC2InstanceActionsWithTagCondition"
  actions = [
    "ec2:RunInstances",
    "ec2:CreateFleet",
    "ec2:CreateLaunchTemplate",
  ]
  resources = [
    "arn:aws:ec2:${data.aws_region.current.name}:*:instance/*",
    "arn:aws:ec2:${data.aws_region.current.name}:*:volume/*",
    "arn:aws:ec2:${data.aws_region.current.name}:*:network-interface/*",
    "arn:aws:ec2:${data.aws_region.current.name}:*:launch-template/*",
  ]
  condition {
    test     = "StringEquals"
    variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
    values   = ["owned"]
  }
  condition {
    test     = "StringLike"
    variable = "aws:RequestTag/karpenter.sh/nodepool"
    values   = ["*"]
  }
}
```

**Rationale**: Enforces mandatory tagging at instance creation:
- `kubernetes.io/cluster/${cluster_name}=owned`: Identifies cluster ownership
- `karpenter.sh/nodepool=<name>`: Tracks which NodePool provisioned the instance

**Why mandatory?**: Without these tags, Karpenter cannot manage or terminate the instances later (see deletion policy below).

### 3.3 Tag Management (Lines 165-182)

```hcl
statement {
  sid = "AllowScopedResourceCreationTagging"
  actions = ["ec2:CreateTags"]
  resources = [
    "arn:aws:ec2:${data.aws_region.current.name}:*:instance/*",
    "arn:aws:ec2:${data.aws_region.current.name}:*:volume/*",
    "arn:aws:ec2:${data.aws_region.current.name}:*:network-interface/*",
    "arn:aws:ec2:${data.aws_region.current.name}:*:launch-template/*",
  ]
  condition {
    test     = "StringEquals"
    variable = "ec2:CreateAction"
    values = [
      "RunInstances",
      "CreateFleet",
      "CreateLaunchTemplate",
    ]
  }
}
```

**Rationale**: Allows tagging only during resource creation (not arbitrary tag modification).

**Security benefit**: Prevents Karpenter from modifying tags on existing resources, reducing blast radius if compromised.

### 3.4 Scoped Deletion (Lines 184-203)

```hcl
statement {
  sid = "AllowScopedDeletion"
  actions = [
    "ec2:TerminateInstances",
    "ec2:DeleteLaunchTemplate",
  ]
  resources = [
    "arn:aws:ec2:${data.aws_region.current.name}:*:instance/*",
    "arn:aws:ec2:${data.aws_region.current.name}:*:launch-template/*",
  ]
  condition {
    test     = "StringEquals"
    variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
    values   = ["owned"]
  }
  condition {
    test     = "StringLike"
    variable = "aws:ResourceTag/karpenter.sh/nodepool"
    values   = ["*"]
  }
}
```

**Rationale**: Critical safety mechanism - Karpenter can only terminate instances with BOTH tags:
- `kubernetes.io/cluster/${cluster_name}=owned`
- `karpenter.sh/nodepool=*` (any NodePool)

**Why critical?**: Prevents Karpenter from accidentally terminating:
- Managed node group instances (different tags)
- Instances from other clusters in the same account
- EC2 instances not related to Kubernetes

### 3.5 Read-Only EC2 Permissions (Lines 205-228)

```hcl
statement {
  sid = "AllowRegionalReadActions"
  actions = [
    "ec2:DescribeAvailabilityZones",
    "ec2:DescribeImages",
    "ec2:DescribeInstances",
    "ec2:DescribeInstanceTypeOfferings",
    "ec2:DescribeInstanceTypes",
    "ec2:DescribeLaunchTemplates",
    "ec2:DescribeSecurityGroups",
    "ec2:DescribeSpotPriceHistory",
    "ec2:DescribeSubnets",
  ]
  resources = ["*"]
}
```

**Rationale**: Karpenter needs to query AWS to make intelligent provisioning decisions:
- **DescribeInstanceTypes**: Find instance types matching NodePool requirements
- **DescribeSpotPriceHistory**: Select cost-effective spot instances
- **DescribeSubnets**: Discover subnets tagged with `karpenter.sh/discovery`
- **DescribeAvailabilityZones**: Spread nodes across AZs for high availability

**Why `*` resources?**: Describe actions don't operate on specific resources; they return lists.

### 3.6 SSM Parameter Store Access (Lines 230-236)

```hcl
statement {
  sid    = "AllowSSMReadActions"
  actions = ["ssm:GetParameter"]
  resources = ["arn:aws:ssm:${data.aws_region.current.name}::parameter/aws/service/*"]
}
```

**Rationale**: EKS-optimized AMI IDs are published by AWS in SSM Parameter Store at paths like:
```
/aws/service/eks/optimized-ami/1.33/amazon-linux-2/recommended/image_id
```

Karpenter queries these parameters to find the latest AMI matching the `amiFamily` (AL2, Bottlerocket, etc.) and cluster version.

### 3.7 Pricing API Access (Lines 238-243)

```hcl
statement {
  sid       = "AllowPricingReadActions"
  actions   = ["pricing:GetProducts"]
  resources = ["*"]
}
```

**Rationale**: Karpenter queries AWS Pricing API to compare on-demand vs spot prices and select the most cost-effective instance types matching workload requirements.

**Cost optimization**: Enables Karpenter to choose between equivalent instance types (e.g., t3.large vs t3a.large) based on real-time pricing.

### 3.8 IAM PassRole (Lines 245-255)

```hcl
statement {
  sid       = "AllowPassingInstanceRole"
  actions   = ["iam:PassRole"]
  resources = [aws_iam_role.karpenter_node.arn]
}
```

**Rationale**: When launching EC2 instances, Karpenter must specify an IAM instance profile. `PassRole` permission is required to attach the Karpenter node IAM role to instances.

**Security scoping**: Restricted to only the Karpenter node role ARN, not `*`. Karpenter cannot attach arbitrary roles to instances.

### 3.9 Instance Profile Management (Lines 257-290)

```hcl
statement {
  sid = "AllowScopedInstanceProfileCreationActions"
  actions = ["iam:CreateInstanceProfile"]
  resources = ["*"]
  condition {
    test     = "StringEquals"
    variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
    values   = ["owned"]
  }
  condition {
    test     = "StringEquals"
    variable = "aws:RequestTag/topology.kubernetes.io/region"
    values   = [data.aws_region.current.name]
  }
  condition {
    test     = "StringLike"
    variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
    values   = ["*"]
  }
}
```

**Rationale**: Karpenter creates instance profiles dynamically for each EC2NodeClass. These profiles wrap the IAM role specified in EC2NodeClass (`role: "aws-2026-eks-karpenter-node"`).

**Why dynamic?**: Allows multiple EC2NodeClasses with different IAM roles (e.g., one for batch workloads, one for web apps).

**Tag enforcement**: Instance profiles must be tagged with cluster name, region, and EC2NodeClass name for tracking.

### 3.10 EKS Cluster API Access (Lines 310-315)

```hcl
statement {
  sid       = "AllowEKSReadActions"
  actions   = ["eks:DescribeCluster"]
  resources = [aws_eks_cluster.main.arn]
}
```

**Rationale**: Karpenter needs to query EKS cluster metadata including:
- Kubernetes API server endpoint
- Cluster certificate authority data
- Cluster security group ID
- OIDC provider URL

**Scoping**: Restricted to the specific cluster ARN, not all clusters in the account.

### 3.11 SQS Interruption Queue Access (Lines 317-373)

```hcl
statement {
  sid = "AllowInterruptionQueueActions"
  actions = [
    "sqs:DeleteMessage",
    "sqs:GetQueueUrl",
    "sqs:ReceiveMessage",
  ]
  resources = [aws_sqs_queue.karpenter_interruption.arn]
}
```

**Rationale**: Karpenter polls the SQS queue for interruption events:
- **EC2 Spot Interruption warnings** (2-minute notice)
- **EC2 Rebalance Recommendations** (proactive spot replacement)
- **EC2 Instance State Change** (terminations)
- **EC2 Health Events** (scheduled maintenance)

**Workflow**:
1. EventBridge rules send events to SQS queue
2. Karpenter receives messages (long polling)
3. Karpenter cordons and drains affected nodes
4. Karpenter deletes processed messages

**Why SQS instead of direct EventBridge?**: SQS provides buffering and at-least-once delivery guarantees.

---

## 4. Karpenter Node IAM Role (karpenter.tf:376-459)

### Code

```hcl
resource "aws_iam_role" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  policy_arn = each.key
  role       = aws_iam_role.karpenter_node.name
}
```

### Rationale

**Purpose**: IAM role attached to Karpenter-provisioned EC2 instances (via instance profile).

**Required AWS Managed Policies**:

1. **AmazonEKSWorkerNodePolicy**
   - Allows kubelet to register node with EKS cluster
   - Grants permissions to describe cluster and node resources
   - Required for basic EKS node functionality

2. **AmazonEKS_CNI_Policy**
   - Used by AWS VPC CNI plugin to manage pod networking
   - Assigns secondary IP addresses to ENIs
   - Attaches/detaches ENIs to instances
   - Required for pod-to-pod networking

3. **AmazonEC2ContainerRegistryReadOnly**
   - Allows kubelet to pull container images from Amazon ECR
   - Includes authentication token retrieval
   - Required if using ECR for container images

4. **AmazonSSMManagedInstanceCore**
   - Enables AWS Systems Manager Session Manager access to nodes
   - Allows remote troubleshooting without SSH keys or bastion hosts
   - Optional but highly recommended for debugging

**Key difference from managed node role**: This role is referenced by name in the EC2NodeClass manifest, while managed nodes use a role created by the EKS node group.

---

## 5. SQS Interruption Queue (karpenter.tf:461-475)

### Code

```hcl
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300  # 5 minutes
  sqs_managed_sse_enabled   = true

  tags = {
    Name        = "${var.cluster_name}-karpenter-interruption"
    Environment = "learning"
  }
}
```

### Rationale

**Message retention: 300 seconds (5 minutes)**
- Spot interruption warnings arrive 2 minutes before termination
- 5-minute retention provides buffer for processing
- Karpenter polls every 5 seconds, so messages are processed quickly
- Longer retention unnecessary and increases storage costs

**SSE encryption: Enabled**
- Encrypts messages at rest using AWS-managed keys
- No performance impact (transparent encryption/decryption)
- Security best practice for sensitive event data

**No DLQ (Dead Letter Queue)**
- Interruption events are time-sensitive
- If Karpenter misses an event, the node is already terminated
- Retrying stale events provides no value
- Simpler configuration reduces operational overhead

---

## 6. EventBridge Rules (karpenter.tf:477-553)

### 6.1 Spot Interruption Rule

```hcl
resource "aws_cloudwatch_event_rule" "karpenter_interruption_spot" {
  name        = "${var.cluster_name}-karpenter-interruption-spot"
  description = "Karpenter spot interruption event rule"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}
```

**Rationale**: Captures 2-minute warning before spot instance termination.

**Karpenter workflow**:
1. Receives spot interruption warning
2. Marks node as unschedulable (`kubectl cordon`)
3. Evicts all pods to other nodes (`kubectl drain`)
4. Provisions replacement node if needed
5. Waits for pod rescheduling to complete before termination

**Benefit**: Minimizes application disruption during spot reclamation.

### 6.2 Rebalance Recommendation Rule

```hcl
resource "aws_cloudwatch_event_rule" "karpenter_interruption_rebalance" {
  name        = "karpenter-interruption-rebalance"
  description = "Karpenter rebalance recommendation event rule"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
}
```

**Rationale**: AWS sends rebalance recommendations when spot instance is at elevated interruption risk (but not yet interrupted).

**Karpenter strategy**:
1. Proactively launches replacement node
2. Waits for replacement to be ready
3. Drains at-risk node gracefully
4. Terminates at-risk node

**Benefit**: Smoother transitions than waiting for interruption warning. Reduces chance of pod evictions under time pressure.

### 6.3 Instance State Change Rule

```hcl
resource "aws_cloudwatch_event_rule" "karpenter_interruption_state_change" {
  name        = "karpenter-interruption-state-change"
  description = "Karpenter instance state change event rule"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state = ["shutting-down", "terminated", "stopping", "stopped"]
    }
  })
}
```

**Rationale**: Catches unexpected instance terminations:
- Manual terminations via console/CLI
- Auto Scaling group scale-down
- Account limits causing launch failures
- AZ issues causing automatic terminations

**Karpenter workflow**:
1. Detects instance termination
2. Removes node from Kubernetes cluster
3. Provisions replacement if pods were running

**Benefit**: Keeps Kubernetes node state synchronized with AWS instance state.

### 6.4 Scheduled Maintenance Rule

```hcl
resource "aws_cloudwatch_event_rule" "karpenter_interruption_health_event" {
  name        = "karpenter-interruption-health-event"
  description = "Karpenter health event rule"

  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
  })
}
```

**Rationale**: AWS publishes health events for scheduled maintenance:
- Hardware degradation requiring instance retirement
- Network maintenance
- Security patching requiring reboots

**Karpenter workflow**:
1. Receives maintenance notification (often 1-2 weeks advance notice)
2. Drains node gracefully before maintenance window
3. Provisions replacement node
4. Allows AWS to perform maintenance without workload impact

---

## 7. VPC Subnet Tags (vpc.tf)

### Code

```hcl
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.cluster_name}-public-${var.availability_zones[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
    "karpenter.sh/discovery"                    = var.cluster_name  # ADDED
  }
}
```

### Rationale

**Discovery tag: `karpenter.sh/discovery = var.cluster_name`**

**Purpose**: Allows Karpenter to dynamically find subnets without hardcoding IDs.

**EC2NodeClass subnet selector**:
```yaml
subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: "aws-2026-eks"
```

**Benefits**:
1. **Multi-AZ support**: Karpenter automatically discovers all subnets with the tag
2. **Environment portability**: Same EC2NodeClass works in dev/staging/prod with different subnet IDs
3. **Dynamic updates**: Add/remove subnets by updating tags, no manifest changes required

**Why not hardcode subnet IDs?**
- Subnet IDs differ across environments
- Hardcoding requires per-environment manifests
- Tag-based selection is Karpenter's recommended best practice

---

## 8. Security Group Tags (security-groups.tf)

### Code

```hcl
resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "Security group for all nodes in the cluster"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name                                        = "${var.cluster_name}-nodes-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "karpenter.sh/discovery"                    = var.cluster_name  # ADDED
  }
}
```

### Rationale

**Discovery tag: `karpenter.sh/discovery = var.cluster_name`**

**Purpose**: Karpenter-provisioned nodes use the same security group as managed nodes.

**Why critical?**
- **Cluster communication**: EKS control plane communicates with nodes on port 443 (kubelet API), 10250 (metrics)
- **Node-to-node traffic**: Pods communicate across nodes; security group must allow this
- **CNI plugin**: AWS VPC CNI uses node security group for pod networking
- **DNS resolution**: CoreDNS runs on managed node; Karpenter nodes must reach it

**EC2NodeClass security group selector**:
```yaml
securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: "aws-2026-eks"
```

**What happens without this tag?**
- Karpenter cannot find security group
- Node provisioning fails with error: "no security groups found matching selector"

---

## 9. EKS Managed Node Taints (eks-nodes.tf)

### Code

```hcl
resource "aws_eks_node_group" "main" {
  # ... other configuration ...

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    role                           = "system"
    "node.kubernetes.io/lifecycle" = "on-demand"
  }
}
```

### Rationale

**Taint: `CriticalAddonsOnly=true:NoSchedule`**

**Purpose**: Reserves managed node exclusively for system components.

**What it blocks**: Application pods without this toleration:
```yaml
tolerations:
- key: CriticalAddonsOnly
  operator: Exists
  effect: NoSchedule
```

**System components that tolerate**:
- CoreDNS (cluster DNS)
- Karpenter controller
- Metrics Server
- AWS Load Balancer Controller
- EBS CSI Driver

**Karpenter Helm configuration** (scripts/install-karpenter.sh):
```bash
--set "tolerations[0].key=CriticalAddonsOnly" \
--set "tolerations[0].operator=Exists" \
--set "tolerations[0].effect=NoSchedule"
```

**Workflow for application pods**:
1. Pod scheduled without toleration
2. Kubernetes cannot schedule on managed node (taint)
3. Pod remains in `Pending` state
4. Karpenter detects unschedulable pod
5. Karpenter provisions new node without taint
6. Pod schedules on new node

**Label: `role=system`**

**Purpose**: Used in Karpenter affinity rules to ensure Karpenter runs on managed node.

**Karpenter Helm configuration**:
```bash
--set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=role" \
--set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=system"
```

**Why necessary?**: Solves chicken-and-egg problem:
- Karpenter provisions nodes
- Karpenter must run on a node
- Solution: Karpenter runs on pre-existing managed node with `role=system` label

**What if Karpenter ran on Karpenter-provisioned node?**
- Node could be consolidated (cost optimization)
- Karpenter pod evicted
- No controller to provision replacement
- Cluster autoscaling stops working

---

## 10. Terraform Providers (providers.tf)

### Code

```hcl
terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
```

### Rationale

**TLS Provider Added**

**Purpose**: Used in `data.tls_certificate.eks` to fetch OIDC provider certificate thumbprint.

**Why needed?**: AWS IAM requires thumbprint verification when trusting OIDC providers.

**Alternative approaches considered**:
1. **Manual thumbprint**: Hardcode thumbprint value
   - **Rejected**: Thumbprint can change if EKS rotates certificates
2. **AWS CLI command**: Run `aws eks describe-cluster` and parse
   - **Rejected**: Not declarative; requires bash and jq
3. **TLS provider** (chosen)
   - Automatically fetches and validates certificate
   - Updates thumbprint if certificate changes
   - Pure Terraform, no external commands

**Helm Provider NOT Added**

**Rationale**: Per user requirement, Terraform only manages infrastructure. Karpenter installation handled by separate Helm script (`scripts/install-karpenter.sh`).

**Benefits of separation**:
- Terraform state not tied to Helm releases
- Can upgrade Karpenter without `terraform apply`
- Helm values easily customized without Terraform changes

---

## 11. Terraform Outputs (outputs.tf)

### Code

```hcl
output "karpenter_controller_role_arn" {
  description = "IAM role ARN for Karpenter controller"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue name for Karpenter interruption handling"
  value       = aws_sqs_queue.karpenter_interruption.name
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider for EKS"
  value       = aws_iam_openid_connect_provider.eks.arn
}
```

### Rationale

**Purpose**: Enable Helm installation script to retrieve dynamic values.

**Usage in install-karpenter.sh**:
```bash
KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn)
CLUSTER_ENDPOINT=$(terraform output -raw cluster_endpoint)
INTERRUPTION_QUEUE=$(terraform output -raw karpenter_interruption_queue_name)

helm upgrade --install karpenter ... \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "settings.interruptionQueue=${INTERRUPTION_QUEUE}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_ROLE_ARN}"
```

**Benefits**:
1. **No hardcoding**: Script works across environments without modification
2. **Single source of truth**: Terraform manages values, script consumes them
3. **Type safety**: `-raw` flag outputs unquoted strings suitable for bash variables

**Why not use data sources in Helm?**
- Helm charts can't query Terraform state
- Outputs are the interface between Terraform and external tools

---

## 12. Karpenter NodePool Configuration

### File: k8s-manifests/karpenter-nodepool-default.yaml

### 12.1 NodePool Resource

```yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]
```

**Rationale: Mixed capacity types**

- **Spot priority**: Karpenter prefers spot instances (70% cost savings)
- **On-demand fallback**: If spot unavailable in all specified instance types, use on-demand
- **Availability over cost**: Application availability is prioritized over maximum cost savings

**When does fallback occur?**
- All spot instance types have insufficient capacity in AZ
- Spot prices exceed on-demand prices (rare but possible)
- Account-level spot limits reached

### 12.2 Instance Family Selection

```yaml
requirements:
  - key: karpenter.k8s.aws/instance-category
    operator: In
    values: ["t"]

  - key: karpenter.k8s.aws/instance-family
    operator: In
    values: ["t3", "t3a"]

  - key: karpenter.k8s.aws/instance-size
    operator: In
    values: ["medium", "large", "xlarge"]
```

**Rationale: t3/t3a families**

| Instance Type | vCPU | Memory | On-Demand Price | Spot Price (avg) | Use Case |
|---------------|------|---------|-----------------|------------------|----------|
| t3.medium     | 2    | 4 GB    | $0.0416/hr      | ~$0.0125/hr      | Small workloads |
| t3.large      | 2    | 8 GB    | $0.0832/hr      | ~$0.0250/hr      | Medium workloads |
| t3.xlarge     | 4    | 16 GB   | $0.1664/hr      | ~$0.0499/hr      | Large workloads |

**Why T3 family?**
- Burstable performance with CPU credits
- Cost-effective for variable workloads
- Sufficient for learning/development environments
- Modern generation (better performance per dollar than t2)

**Why T3a included?**
- AMD processors (vs Intel in t3)
- 10% cheaper than t3
- Same CPU credits and burst behavior
- Increases spot availability (more instance types = higher fulfillment rate)

**Why these sizes?**
- **medium**: Matches current managed node size
- **large/xlarge**: Allows consolidation of multiple pods on single node
- **Excluded 2xlarge+**: Reduces blast radius (fewer pods per node = less disruption)

**Alternative families considered**:
- **m5/m6i**: General-purpose but 2x cost for learning environment
- **c5**: Compute-optimized, overkill for web workloads
- **t4g** (ARM): Cheapest but requires multi-arch container images

### 12.3 Resource Limits

```yaml
limits:
  cpu: "100"
  memory: "200Gi"
```

**Rationale**:

**Max cluster capacity**: ~25 t3.xlarge nodes (4 vCPU × 25 = 100 vCPU)

**Safety guardrails**:
- Prevents runaway scaling from misconfigured deployments
- Protects against cost surprises (100 vCPU ≈ $300/month spot)
- Stops attacks from compromised workloads requesting excessive resources

**Appropriate for learning environment**: Production would typically use much higher limits or per-team NodePools with individual limits.

### 12.4 Disruption and Consolidation

```yaml
disruption:
  consolidationPolicy: WhenUnderutilized
  consolidateAfter: 30s

  budgets:
    - nodes: "10%"
```

**Rationale: `WhenUnderutilized` policy**

**How consolidation works**:
1. Karpenter detects nodes using <50% of requested resources
2. Simulates bin-packing pods onto fewer nodes
3. If successful, launches replacement nodes (if needed)
4. Drains and terminates underutilized nodes

**Example scenario**:
- 4 nodes, each running pods requesting 1 vCPU
- Each t3.large has 2 vCPU capacity
- Karpenter consolidates to 2 nodes, each running 2 vCPU of pods
- Saves 2 × $0.0250/hr = $0.05/hr = $36/month

**`consolidateAfter: 30s`**

**Rationale**: Short consolidation delay reduces cost quickly.

**Tradeoff**:
- **Shorter (30s)**: Faster cost reduction, more churn
- **Longer (5-10 minutes)**: Less churn, slower cost response

**Why 30s for learning**: Quick feedback loop to observe consolidation behavior.

**Production recommendation**: 300s (5 minutes) to reduce churn.

**Disruption budget: `10%`**

**Purpose**: Limits concurrent disruptions to prevent availability issues.

**Example**:
- 10 Karpenter nodes in cluster
- Budget allows 1 node (10%) to be disrupted at a time
- Karpenter waits for disruption to complete before starting next

**Why needed?**
- PodDisruptionBudgets (PDBs) can block node drains
- Multiple simultaneous drains can cause pod scheduling bottlenecks
- Gradual disruption reduces blast radius

---

## 13. EC2NodeClass Configuration

### File: k8s-manifests/karpenter-nodepool-default.yaml

```yaml
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2

  role: "aws-2026-eks-karpenter-node"

  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "aws-2026-eks"

  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "aws-2026-eks"

  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: "20Gi"
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true

  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required  # IMDSv2
```

### 13.1 AMI Family

**`amiFamily: AL2`**

**Rationale**: Uses EKS-optimized Amazon Linux 2 AMI.

**What's included in EKS-optimized AMI?**
- Kubernetes binaries (kubelet, kubectl) matching cluster version
- Docker or containerd runtime
- AWS VPC CNI plugin
- SSM agent for Session Manager
- Optimized kernel parameters for container workloads

**AMI selection process**:
1. Karpenter queries SSM Parameter Store: `/aws/service/eks/optimized-ami/1.33/amazon-linux-2/recommended/image_id`
2. AWS publishes latest AMI ID with security patches
3. Karpenter automatically uses latest AMI (no manual AMI ID updates required)

**Alternative AMI families**:
- **AL2023**: Amazon Linux 2023 (newer but less mature ecosystem)
- **Bottlerocket**: Minimal OS optimized for containers (advanced use case)
- **Ubuntu**: Community-supported EKS AMI

### 13.2 IAM Role

**`role: "aws-2026-eks-karpenter-node"`**

**Rationale**: References IAM role by name (not ARN).

**Why name instead of ARN?**
- Karpenter creates instance profiles dynamically
- Instance profile names must match role names
- Terraform output `karpenter_node_instance_profile_name` exports role name

**Role attachment process**:
1. Karpenter calls `iam:CreateInstanceProfile` with name matching role name
2. Karpenter calls `iam:AddRoleToInstanceProfile` to attach role
3. Karpenter calls `ec2:RunInstances` with `IamInstanceProfile={Name=role_name}`
4. Instance boots with role permissions

### 13.3 Resource Selectors

**Subnet selector**: Tag-based discovery (explained in Section 7)

**Security group selector**: Tag-based discovery (explained in Section 8)

**Why not use IDs?**
```yaml
# Antipattern - DO NOT USE
subnetSelectorTerms:
  - id: subnet-abc123
  - id: subnet-def456
```

**Problems with ID-based selection**:
- Brittle: Breaks if subnets are recreated
- Not portable: Different IDs in dev/staging/prod
- Manual maintenance: Must update manifest when adding/removing subnets

### 13.4 EBS Configuration

**Volume size: 20Gi**

**Rationale**: Sufficient for:
- OS and system packages: ~2 GB
- Container image layers: ~10 GB (typical)
- Ephemeral pod storage: ~5 GB
- Logs: ~3 GB

**Cost**: $0.08/GB/month × 20 GB = $1.60/month per node

**Volume type: gp3**

**Rationale**: General Purpose SSD with:
- 3,000 IOPS baseline (vs gp2's scaled IOPS)
- 125 MB/s throughput baseline
- 20% cheaper than gp2
- Same latency as gp2

**Encryption: Required**

**Rationale**:
- Security best practice (defense in depth)
- Compliance requirement for many regulated industries
- No performance penalty with gp3
- Uses AWS-managed keys (no key management overhead)

**Delete on termination: True**

**Rationale**:
- Ephemeral nodes shouldn't have persistent data
- StatefulSets should use EBS CSI driver for persistent volumes
- Prevents orphaned volumes accumulating costs
- Typical cost leak: 100 orphaned 20GB volumes = $160/month wasted

### 13.5 Instance Metadata Service (IMDS)

**`httpTokens: required` (IMDSv2)**

**Rationale**: Security hardening against SSRF attacks.

**IMDSv1 vulnerability**:
```bash
# Attacker exploits SSRF in application
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/role-name
# Returns temporary AWS credentials
```

**IMDSv2 protection**:
```bash
# Step 1: Obtain session token (requires PUT request - SSRF typically uses GET)
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Step 2: Use token in header (SSRF cannot set custom headers)
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/role-name -H "X-aws-ec2-metadata-token: $TOKEN"
```

**Why SSRF blocked**: Most SSRF vulnerabilities:
- Cannot send PUT requests (only GET)
- Cannot set custom HTTP headers
- IMDSv2 requires both

**Hop limit: 2**

**Rationale**: Allows metadata access from containers (1 hop from host) but prevents access from nested containers or pods using host networking.

---

## 14. Helm Installation Script

### File: scripts/install-karpenter.sh

### Key Sections

```bash
# Get outputs from Terraform
KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn)
CLUSTER_ENDPOINT=$(terraform output -raw cluster_endpoint)
INTERRUPTION_QUEUE=$(terraform output -raw karpenter_interruption_queue_name)
```

**Rationale**: Dynamic value retrieval ensures script works across environments without modification.

```bash
aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws
```

**Rationale**: Karpenter Helm chart is hosted in Amazon ECR Public registry, which requires authentication even for public repositories.

**Why ECR Public?**
- Native AWS integration
- High availability and performance for AWS users
- Simpler authentication than Docker Hub rate limits

```bash
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "0.37.2" \
  --namespace karpenter \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "settings.interruptionQueue=${INTERRUPTION_QUEUE}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_ROLE_ARN}"
```

**Critical parameters**:

1. **`settings.clusterName`**: Used for:
   - Tagging provisioned instances
   - Querying EKS API
   - Filtering CloudWatch events

2. **`settings.clusterEndpoint`**: Kubernetes API server URL
   - Karpenter calls API to create Node objects
   - Must be reachable from Karpenter pods

3. **`settings.interruptionQueue`**: SQS queue name for polling interruption events

4. **`serviceAccount.annotations.eks\.amazonaws\.com/role-arn`**: IRSA configuration
   - Enables Karpenter service account to assume IAM role
   - No AWS credentials stored in cluster

**Affinity and toleration settings**:
```bash
--set "tolerations[0].key=CriticalAddonsOnly" \
--set "tolerations[0].operator=Exists" \
--set "tolerations[0].effect=NoSchedule" \
--set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=role" \
--set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=system"
```

**Rationale**: Ensures Karpenter runs on managed node with `role=system` label and tolerates the `CriticalAddonsOnly` taint.

---

## 15. Cost Analysis

### Current Setup (Before Karpenter)

| Resource | Quantity | Unit Cost | Monthly Cost |
|----------|----------|-----------|--------------|
| EKS Cluster | 1 | $73.00 | $73.00 |
| t3.medium (managed) | 2 | $30.00 | $60.00 |
| EBS gp3 20GB | 2 | $1.60 | $3.20 |
| Data transfer (estimate) | - | - | $5.00 |
| **TOTAL** | | | **$141.20** |

### With Karpenter (After)

#### Fixed Costs
| Resource | Quantity | Unit Cost | Monthly Cost |
|----------|----------|-----------|--------------|
| EKS Cluster | 1 | $73.00 | $73.00 |
| t3.medium (managed) | 1 | $30.00 | $30.00 |
| EBS gp3 20GB (managed) | 1 | $1.60 | $1.60 |
| SQS queue | 1 | ~$0.00 | $0.10 |

**Fixed total: $104.70/month**

#### Variable Costs (Application Nodes)

**Scenario 1: Steady 2-node workload (spot)**
| Resource | Quantity | Unit Cost (spot) | Monthly Cost |
|----------|----------|------------------|--------------|
| t3.medium (spot) | 2 | ~$9.00 | $18.00 |
| EBS gp3 20GB | 2 | $1.60 | $3.20 |

**Total: $104.70 + $21.20 = $125.90/month**
**Savings vs current: $15.30/month (11%)**

**Scenario 2: Bursty workload (5 nodes for 6 hours/day, spot)**
- 5 nodes × 6 hours/day = 30 node-hours/day = 900 node-hours/month
- t3.medium spot: ~$0.0125/hour
- Cost: 900 hours × $0.0125 = $11.25/month
- EBS: 5 volumes × $1.60 = $8.00
- **Total: $104.70 + $19.25 = $123.95/month**
- **Savings vs current: $17.25/month (12%)**

**Scenario 3: Consolidated workload (1 t3.xlarge instead of 2 t3.medium)**
- 1 t3.xlarge (4 vCPU, 16 GB) vs 2 t3.medium (2 vCPU, 8 GB each)
- Same total capacity but better bin-packing efficiency
- t3.xlarge spot: ~$0.0499/hour = $35.93/month
- EBS: 1 volume × $1.60 = $1.60
- **Total: $104.70 + $37.53 = $142.23/month**
- **Savings: -$1.03 (slight increase but improved resource utilization)**

### Cost Savings Mechanisms

1. **Spot instances**: 70% savings over on-demand
2. **Consolidation**: 15-25% reduction by using fewer, larger nodes
3. **Scale-to-zero**: No application node costs when idle
4. **Right-sizing**: Karpenter selects cheapest instance type meeting requirements

### Break-Even Analysis

**When does Karpenter save money?**
- **Bursty workloads**: >20% time with <2 nodes
- **Overprovisioned workloads**: Current nodes have >40% idle capacity
- **Growing workloads**: Adding 3+ nodes would trigger savings

**When is it not worth it?**
- **Steady 3+ nodes**: Fixed on-demand instances simpler
- **Tiny clusters**: Karpenter operational overhead may exceed savings
- **High spot interruption rate**: Frequent interruptions increase data transfer costs

---

## 16. Security Considerations

### Principle of Least Privilege

**Karpenter Controller**: Only manages nodes it created
- Scoped deletion policies prevent terminating managed nodes
- Tag-based conditions enforce cluster isolation

**Karpenter Nodes**: Standard EKS node permissions
- No special privileges beyond managed nodes
- Same security posture as node groups

### Defense in Depth

1. **IRSA**: No long-lived AWS credentials in cluster
2. **IMDSv2**: Protects against SSRF credential theft
3. **Encrypted EBS**: Data at rest encryption
4. **SQS encryption**: Event data encrypted in transit and at rest
5. **Scoped IAM policies**: Cannot accidentally affect other clusters

### Attack Surface

**New components introduced**:
- SQS queue (only writable by EventBridge, readable by Karpenter)
- OIDC provider (standard EKS IRSA mechanism)
- IAM roles (scoped to specific actions and resources)

**Risk assessment**: Minimal increase in attack surface; all components use AWS best practices.

---

## 17. Operational Considerations

### Monitoring

**Key metrics to watch**:
```bash
# Karpenter controller health
kubectl get pods -n karpenter
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100

# Node provisioning
kubectl get nodeclaims -n karpenter
kubectl describe nodepool default -n karpenter

# Cost tracking
aws ec2 describe-instances --filters "Name=tag:karpenter.sh/nodepool,Values=*" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,State:State.Name,Lifecycle:InstanceLifecycle}'

# Consolidation activity
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | grep -i consolidation
```

### Troubleshooting

**Pods not scheduling**:
```bash
kubectl describe pod <pod-name>
# Look for: "0/1 nodes available: 1 node(s) had taint that the pod didn't tolerate"

kubectl describe nodepool default -n karpenter
# Check conditions for errors

kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100
# Look for: "no instance types match requirements"
```

**Common issues**:
1. **No capacity in AZ**: Spot unavailable; Karpenter retries with on-demand
2. **Instance type not available**: Widen instance type requirements in NodePool
3. **Subnet not found**: Check `karpenter.sh/discovery` tags on subnets
4. **Security group not found**: Check `karpenter.sh/discovery` tags on SG

### Upgrade Path

**Karpenter 0.37.2 → Future versions**:

1. Backup current configuration:
   ```bash
   kubectl get nodepools -n karpenter -o yaml > backup-nodepools.yaml
   kubectl get ec2nodeclasses -n karpenter -o yaml > backup-ec2nodeclasses.yaml
   ```

2. Update Helm installation:
   ```bash
   # Edit scripts/install-karpenter.sh
   KARPENTER_VERSION="0.38.0"  # Or newer

   # Run installation script
   ./scripts/install-karpenter.sh
   ```

3. Verify:
   ```bash
   kubectl get pods -n karpenter
   kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter
   ```

**Breaking changes to watch for**:
- API version changes (v1alpha5 → v1beta1 → v1)
- NodePool/EC2NodeClass schema changes
- IAM policy updates (check Karpenter release notes)

---

## 18. Testing Workflow

### Initial Testing

```bash
# 1. Verify Karpenter is running
kubectl get pods -n karpenter

# 2. Apply NodePool configuration
kubectl apply -f k8s-manifests/karpenter-nodepool-default.yaml

# 3. Verify NodePool is ready
kubectl get nodepools -n karpenter
kubectl describe nodepool default -n karpenter

# 4. Deploy test workload
kubectl apply -f k8s-manifests/test-deployment.yaml

# 5. Scale up to trigger provisioning
kubectl scale deployment inflate --replicas=5

# 6. Watch node creation
kubectl get nodes --watch

# 7. Check provisioning logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=50 --follow

# 8. Verify pods scheduled
kubectl get pods -o wide
```

### Consolidation Testing

```bash
# 1. Scale down deployment
kubectl scale deployment inflate --replicas=0

# 2. Watch for consolidation (should occur after 30 seconds)
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | grep -i consolidation

# 3. Verify nodes terminating
kubectl get nodes --watch
```

### Spot Interruption Simulation

```bash
# 1. Find Karpenter-provisioned spot instance
INSTANCE_ID=$(kubectl get nodes -l karpenter.sh/nodepool=default -o jsonpath='{.items[0].spec.providerID}' | cut -d'/' -f5)

# 2. Terminate instance
aws ec2 terminate-instances --instance-ids $INSTANCE_ID

# 3. Watch Karpenter detect termination and provision replacement
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=50 --follow
```

---

## 19. References

### Official Documentation
- [Karpenter Documentation](https://karpenter.sh/)
- [Karpenter AWS Provider](https://karpenter.sh/docs/concepts/nodeclasses/)
- [EKS Best Practices - Karpenter](https://aws.github.io/aws-eks-best-practices/karpenter/)
- [IRSA Documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)

### AWS Documentation
- [EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/)
- [EC2 Spot Instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html)
- [IMDSv2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)

### Related Files
- `karpenter.tf`: Infrastructure definitions
- `scripts/install-karpenter.sh`: Helm installation automation
- `k8s-manifests/karpenter-nodepool-default.yaml`: NodePool and EC2NodeClass configuration
- `k8s-manifests/test-deployment.yaml`: Test workload

---

## 20. Summary

This Karpenter setup provides:

**Cost Optimization**:
- 11-12% immediate savings through spot instances and consolidation
- Scale-to-zero capability for idle workloads
- Right-sizing to match actual resource needs

**Operational Benefits**:
- Automatic node provisioning based on pod requirements
- Graceful spot interruption handling
- Consolidation to reduce waste

**Security**:
- IRSA for credential management
- IMDSv2 enforcement
- Scoped IAM policies
- Encrypted storage

**Scalability**:
- Supports multiple instance types and sizes
- Multi-AZ deployment
- Tag-based resource discovery for environment portability

**Maintainability**:
- Clear separation between infrastructure (Terraform) and application (Helm)
- Comprehensive outputs for automation
- Upgrade path documented

This setup is production-ready with appropriate adjustments to NodePool limits and disruption budgets for your specific workload requirements.
