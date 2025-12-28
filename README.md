# aws-2026

AWS EKS infrastructure provisioned with Terraform. Cost-optimized setup with public subnets only.

## Infrastructure Overview

- **Region:** us-east-1
- **VPC CIDR:** 10.59.0.0/16
- **Availability Zones:** 2 (us-east-1a, us-east-1b)
- **Subnets:** Public subnets only (10.59.0.0/18, 10.59.64.0/18)
- **EKS Version:** 1.33
- **Node Type:** Managed node group with t3.medium instances
- **Cost:** ~$141-146/month

## Architecture Decisions

**Cost Optimization:**
- No NAT Gateways (saves ~$33/month)
- All resources in public subnets with direct internet gateway access
- 7-day CloudWatch log retention
- Minimal node disk size (20GB)

**Security:**
- Security groups control all traffic
- EKS API accessible from anywhere (requires AWS authentication)
- All control plane logs enabled for auditing

## Prerequisites

Before using this Terraform configuration, ensure you have:

1. **AWS CLI** installed and configured
   ```bash
   aws configure
   # Enter your AWS Access Key ID, Secret Access Key, and default region (us-east-1)
   ```

2. **Verify AWS credentials**
   ```bash
   aws sts get-caller-identity
   ```

3. **Terraform** installed (>= 1.12.0)
   ```bash
   # macOS
   brew install terraform

   # Or download from https://www.terraform.io/downloads
   ```

4. **kubectl** installed
   ```bash
   # macOS
   brew install kubectl
   ```

5. **aws-iam-authenticator** installed
   ```bash
   # macOS
   brew install aws-iam-authenticator
   ```

## Deployment

### 1. Initialize Terraform

```bash
terraform init
```

This downloads the AWS provider and initializes the working directory.

### 2. Validate Configuration

```bash
terraform validate
```

### 3. Review the Plan

```bash
terraform plan -out=tfplan
```

Review the resources that will be created. You should see:
- 1 VPC
- 1 Internet Gateway
- 2 Public Subnets
- Security Groups
- EKS Cluster
- Managed Node Group
- IAM Roles and Policies

### 4. Apply the Configuration

```bash
terraform apply tfplan
```

This will take approximately 10-15 minutes. The EKS cluster creation is the slowest part.

### 5. Configure kubectl

After the infrastructure is created, configure kubectl to access your cluster:

```bash
aws eks update-kubeconfig --region us-east-1 --name aws-2026-eks
```

### 6. Verify the Cluster

```bash
# Check nodes
kubectl get nodes

# Check system pods
kubectl get pods -A

# Check cluster info
kubectl cluster-info
```

You should see 2 nodes in the `Ready` state.

## Customization

To customize the infrastructure, edit `terraform.tfvars`:

```hcl
cluster_name       = "my-custom-name"
node_instance_type = "t3.large"
node_desired_size  = 3
# etc.
```

Then run `terraform plan` and `terraform apply` again.

## Cost Management

**Monthly Cost Breakdown:**
- EKS Cluster: ~$73/month ($0.10/hour)
- 2x t3.medium instances: ~$60/month ($0.0416/hour each)
- EBS volumes (20GB): ~$3.20/month
- Data transfer: ~$5-10/month
- **Total: ~$141-146/month**

**Cost Savings:**
- No NAT Gateway: **Saves $33/month** (+ data processing charges)

**Further Cost Optimization:**
- Use SPOT instances: Change `capacity_type = "SPOT"` in `eks-nodes.tf` (saves ~70% on compute)
- Reduce node count during non-use hours
- Delete the cluster when not needed: `terraform destroy`

## Cleanup

To destroy all infrastructure and avoid charges:

```bash
# 1. Delete all Kubernetes resources first (important!)
kubectl delete all --all --all-namespaces

# 2. Wait for cleanup
sleep 60

# 3. Destroy Terraform resources
terraform destroy
```

**Important:** Always delete Kubernetes-managed resources (LoadBalancers, Persistent Volumes) before running `terraform destroy`. These resources are created outside of Terraform and can prevent VPC deletion.

## File Structure

```
.
├── .gitignore              # Git ignore rules
├── providers.tf            # Terraform and AWS provider configuration
├── variables.tf            # Variable definitions
├── terraform.tfvars        # Variable values (not committed to git)
├── data.tf                 # Data sources
├── vpc.tf                  # VPC, subnets, internet gateway
├── security-groups.tf      # Security groups for cluster and nodes
├── eks-cluster.tf          # EKS cluster and IAM roles
├── eks-nodes.tf            # Managed node group
└── outputs.tf              # Useful outputs
```

## Troubleshooting

### Nodes not joining cluster
- Check security group rules in `security-groups.tf`
- Verify IAM role policies are attached correctly
- Check CloudWatch logs: `/aws/eks/aws-2026-eks/cluster`

### kubectl connection issues
```bash
# Re-run kubeconfig update
aws eks update-kubeconfig --region us-east-1 --name aws-2026-eks

# Verify credentials
aws sts get-caller-identity
```

### Terraform destroy fails
- Ensure all Kubernetes-managed resources are deleted first
- Check for LoadBalancers: `kubectl get svc --all-namespaces`
- Check for Persistent Volumes: `kubectl get pv`

## Security Considerations

**Current Setup (Learning/Development):**
- EKS API accessible from 0.0.0.0/0 (requires AWS authentication)
- Nodes have public IPs
- All traffic controlled by security groups

**For Production:**
- Restrict API access: Change `public_access_cidrs` in `eks-cluster.tf` to your IP
- Add private subnets with NAT gateway for nodes
- Enable encryption at rest
- Implement Kubernetes network policies
- Use AWS Secrets Manager for sensitive data

## Next Steps

After the cluster is running, consider:

1. **Install AWS Load Balancer Controller** for ingress
2. **Install EBS CSI Driver** for persistent volumes
3. **Install Metrics Server** for `kubectl top` commands
4. **Set up monitoring** with Prometheus/Grafana or CloudWatch Container Insights
5. **Implement cluster autoscaler** for automatic node scaling

## Resources

- [EKS Documentation](https://docs.aws.amazon.com/eks/)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
