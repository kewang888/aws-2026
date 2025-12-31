# Karpenter Troubleshooting Guide

This document captures all the issues encountered and solutions found while setting up Karpenter v1.7.4 on EKS 1.32 with Amazon Linux 2.

---

## Issues Encountered & Solutions

### 1. API Version Mismatch (v1beta1 vs v1)

**Problem:** Started with Karpenter 0.37.2 using v1beta1 API, which had poor AL2023 support.

**Symptoms:**
- Nodes not joining cluster with AL2023
- API schema validation errors

**Troubleshooting Steps:**
```bash
# Check available CRD versions
kubectl get crd nodepools.karpenter.sh -o jsonpath='{.spec.versions[*].name}'
kubectl get crd ec2nodeclasses.karpenter.k8s.aws -o jsonpath='{.spec.versions[*].name}'
```

**Issues Found:**
- v1beta1 API had incomplete AL2023 support in Karpenter 0.37.2
- v1 API requires different schema (e.g., nodeClassRef needs `group` and `kind`)
- v1 disruption policy values changed: `WhenUnderutilized` → `WhenEmptyOrUnderutilized`

**Solution:**
1. Upgraded to Karpenter v1.7.4
2. Updated manifests to use v1 API:
   ```yaml
   # Before (v1beta1)
   apiVersion: karpenter.sh/v1beta1
   spec:
     template:
       spec:
         nodeClassRef:
           apiVersion: karpenter.k8s.aws/v1beta1
           kind: EC2NodeClass
           name: default

   # After (v1)
   apiVersion: karpenter.sh/v1
   spec:
     template:
       spec:
         nodeClassRef:
           group: karpenter.k8s.aws
           kind: EC2NodeClass
           name: default
   ```

3. Fixed disruption policy:
   ```yaml
   # Before
   disruption:
     consolidationPolicy: WhenUnderutilized
     consolidateAfter: 30s  # Not allowed with this policy

   # After
   disruption:
     consolidationPolicy: WhenEmptyOrUnderutilized
     consolidateAfter: 1m
   ```

---

### 2. CRD Conversion Webhook Errors

**Problem:**
```
Error: conversion webhook for karpenter.sh/v1beta1, Kind=NodeClaim failed:
Post "https://karpenter.kube-system.svc:8443/?timeout=30s": service "karpenter" not found
```

**Symptoms:**
- Unable to list or describe nodeclaims
- kubectl commands failing with webhook errors

**Troubleshooting Steps:**
```bash
# Check CRD conversion webhook configuration
kubectl get crd nodeclaims.karpenter.sh -o yaml | grep -A10 "conversion:"

# Output showed:
# conversion:
#   strategy: Webhook
#   webhook:
#     clientConfig:
#       service:
#         name: karpenter
#         namespace: kube-system  # Wrong! Should be "karpenter"
#         port: 8443              # Wrong! Should be 8000

# Check actual Karpenter service
kubectl get svc -n karpenter
# NAME        TYPE        CLUSTER-IP     PORT(S)
# karpenter   ClusterIP   172.20.97.97   8000/TCP

# Check validating/mutating webhooks
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations | grep -i karpenter
# (Found no webhooks - Karpenter doesn't use them in this version)
```

**Root Cause:**
- CRD conversion webhooks were misconfigured pointing to wrong namespace and port
- Karpenter v1.7.4 doesn't actually use conversion webhooks
- We only used v1 API, so conversion wasn't needed

**Solution:** Disabled conversion webhooks on all Karpenter CRDs:
```bash
# Disable conversion for NodeClaims
kubectl patch crd nodeclaims.karpenter.sh --type='json' \
  -p='[{"op": "replace", "path": "/spec/conversion", "value": {"strategy": "None"}}]'

# Disable conversion for NodePools
kubectl patch crd nodepools.karpenter.sh --type='json' \
  -p='[{"op": "replace", "path": "/spec/conversion", "value": {"strategy": "None"}}]'

# Disable conversion for EC2NodeClasses
kubectl patch crd ec2nodeclasses.karpenter.k8s.aws --type='json' \
  -p='[{"op": "replace", "path": "/spec/conversion", "value": {"strategy": "None"}}]'
```

**Verification:**
```bash
kubectl get nodeclaims  # Should work now
```

---

### 3. Spot Instance Service-Linked Role Missing

**Problem:**
```json
{
  "level":"ERROR",
  "message":"Reconciler error",
  "error":"launching nodeclaim, creating instance, with fleet error(s),
   AuthFailure.ServiceLinkedRoleCreationNotPermitted: The provided credentials
   do not have permission to create the service-linked role for EC2 Spot Instances."
}
```

**Symptoms:**
- NodeClaims stuck in failed state
- Karpenter logs showing spot instance permission errors

**Troubleshooting Steps:**
```bash
# Check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100

# Check nodeclaim status
kubectl describe nodeclaim <name>
```

**Root Cause:**
AWS account didn't have the EC2 Spot service-linked role created yet (one-time setup per account).

**Solutions (2 options):**

**Option A:** Create the service-linked role:
```bash
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

**Option B:** Use only on-demand instances (chosen for this setup):
```yaml
# In karpenter-nodepool-default.yaml
requirements:
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["on-demand"]  # Removed "spot"
```

---

### 4. IAM Permission Missing (ListInstanceProfiles)

**Problem:**
```json
{
  "level":"ERROR",
  "controller":"instanceprofile.garbagecollection",
  "aws-error-code":"AccessDenied",
  "error":"listing instance profiles, User is not authorized to perform:
   iam:ListInstanceProfiles on resource: arn:aws:iam::069057294951:instance-profile/"
}
```

**Symptoms:**
- Karpenter logs showing AccessDenied errors
- NodePool status showing "not ready"

**Troubleshooting Steps:**
```bash
# Check Karpenter controller logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | grep -i error

# Check NodePool status
kubectl get nodepool default -o yaml | grep -A20 "status:"
```

**Root Cause:**
Karpenter v1.7.4 introduced a garbage collection feature for instance profiles that requires `iam:ListInstanceProfiles` permission.

**Solution:** Added missing permission to Karpenter controller IAM policy in `karpenter.tf`:
```hcl
statement {
  sid = "AllowInstanceProfileReadActions"
  actions = [
    "iam:GetInstanceProfile",
    "iam:ListInstanceProfiles",  # ADDED THIS
  ]
  resources = ["*"]
  effect    = "Allow"
}
```

Then applied the change:
```bash
terraform apply -auto-approve
```

**Verification:**
```bash
# Errors should stop appearing in logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=50
```

---

### 5. AL2023 Cloud-Init Warning

**Problem:**
```
cloud-init[2156]: 2025-12-28 20:35:39,951 - __init__.py[WARNING]:
Unhandled unknown content-type (application/node.eks.aws) userdata: 'b'# Karpenter Generated No'...'
```

**Symptoms:**
- Nodes launched but didn't join cluster
- Console output showing cloud-init warning

**Troubleshooting Steps:**
```bash
# Get instance ID from nodeclaim
kubectl describe nodeclaim <name> | grep "Provider ID"
# Provider ID: aws:///us-east-1a/i-xxxxx

# Check console output
aws ec2 get-console-output --instance-id i-xxxxx --region us-east-1 --latest

# Look for errors
aws ec2 get-console-output --instance-id i-xxxxx --region us-east-1 --latest \
  | grep -i "error\|warn\|fail"
```

**Understanding the Issue:**

AL2023 uses a new bootstrap process with `nodeadm`:

```
Traditional AL2 Bootstrap:
┌─────────────┐
│ cloud-init  │ → Runs /etc/eks/bootstrap.sh → Joins cluster
└─────────────┘

AL2023 Bootstrap:
┌─────────────┐     ┌──────────┐
│ cloud-init  │ → → │ nodeadm  │ → Reads NodeConfig → Joins cluster
└─────────────┘     └──────────┘
     ↓
  WARNING: Unhandled content-type (application/node.eks.aws)
  (This is expected - cloud-init doesn't handle it, nodeadm does)
```

**What Karpenter Generates:**
```yaml
# Multipart MIME user data
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: application/node.eks.aws

# Karpenter Generated NodeConfig
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: aws-2026-eks
    apiServerEndpoint: https://xxx.eks.amazonaws.com
    certificateAuthority: LS0tLS1...
    cidr: 172.20.0.0/16
  kubelet:
    config:
      clusterDNS: ["172.20.0.10"]
      maxPods: 58
    flags:
      - --node-labels="karpenter.sh/nodepool=default,..."
```

**Finding:**
The warning is **expected** and harmless. However, with Karpenter 0.37.2, nodes still didn't join properly. The issue was actually the missing aws-auth ConfigMap entry (see issue #9).

**Temporary Solution:**
Switched to AL2 for immediate success, since:
- EKS 1.33 only has AL2023 AMIs
- EKS 1.32 still has AL2 AMIs
- AL2 uses familiar `/etc/eks/bootstrap.sh`

**Future Solution:**
Once aws-auth issue is fixed, AL2023 should work with EKS 1.33 + Karpenter v1.7.4.

---

### 6. Wrong AMI Selected

**Problem:** Karpenter selected custom AMIs instead of AWS EKS-optimized AMIs:
- "Offseclab Base AMI" (ami-03ad4f0274233f98e)
- Custom ARM AMI (ami-0080bff0e29a1dfca)

**Symptoms:**
- NodePool status: `AMIsReady=False`
- Nodes failing to boot or join
- Instance boot errors in console output

**Troubleshooting Steps:**
```bash
# Check EC2NodeClass status
kubectl get ec2nodeclass default -o yaml | grep -A30 "status:"

# Check which AMIs were resolved
kubectl get ec2nodeclass default -o jsonpath='{.status.amis}' | jq .

# Output showed wrong AMIs:
# [
#   {
#     "id": "ami-03ad4f0274233f98e",
#     "name": "Offseclab Base AMI",  # NOT an EKS AMI!
#     ...
#   }
# ]

# Search for correct EKS AMIs
aws ec2 describe-images \
  --owners 602401143452 \
  --filters "Name=name,Values=amazon-eks-node-1.32-*" \
  --region us-east-1 \
  --query 'Images[*].[ImageId,Name]' \
  --output table
```

**Root Cause:**
Using `alias: al2023@latest` or `alias: al2@latest` without owner filter caused Karpenter to match custom AMIs in the account.

**Solution:** Use explicit AMI selector with AWS's owner ID:
```yaml
# Before (Wrong - matches any AMI with this name pattern)
spec:
  amiFamily: AL2
  amiSelectorTerms:
    - alias: al2@latest

# After (Correct - only matches AWS official AMIs)
spec:
  amiFamily: AL2
  amiSelectorTerms:
    - owner: "602401143452"  # AWS EKS AMI account
      name: "amazon-eks-node-1.32-*"
```

**Key Learning:**
- `602401143452` = AWS's official account ID for EKS AMIs
- Always use owner filter in shared/production accounts
- Check resolved AMIs in EC2NodeClass status

**Verification:**
```bash
# Check that correct AMI is resolved
kubectl get ec2nodeclass default -o jsonpath='{.status.amis}' | jq .

# Should show AWS EKS AMI like:
# {
#   "id": "ami-071a9f2683c2da4bd",
#   "name": "amazon-eks-node-1.32-v20241216",
#   ...
# }
```

---

### 7. No AL2 AMIs for EKS 1.33

**Problem:**
```yaml
status:
  conditions:
    - message: AMISelector did not match any AMIs
      reason: AMINotFound
      status: "False"
      type: AMIsReady
```

**Symptoms:**
- NodePool not becoming ready
- No nodeclaims created
- EC2NodeClass showing AMI not found

**Troubleshooting Steps:**
```bash
# Check NodePool status
kubectl get nodepool default -o yaml | grep -A20 "status:"

# Check EC2NodeClass status
kubectl get ec2nodeclass default -o yaml | grep -A30 "status:"

# Search for AL2 AMIs for EKS 1.33
aws ec2 describe-images \
  --owners 602401143452 \
  --filters "Name=name,Values=amazon-eks-node-1.33-*" \
  --region us-east-1

# Result: No images found!

# Search for AL2023 AMIs for EKS 1.33
aws ec2 describe-images \
  --owners 602401143452 \
  --filters "Name=name,Values=amazon-eks-node-al2023-x86_64-standard-1.33-*" \
  --region us-east-1

# Result: AMIs exist for AL2023!
```

**Root Cause:**
AWS stopped publishing Amazon Linux 2 (AL2) AMIs on **November 26, 2025**. EKS 1.33 and newer versions only have AL2023 AMIs available.

Reference: https://docs.aws.amazon.com/eks/latest/userguide/al2023.html

**Solution:** Downgraded to EKS 1.32 which still has AL2 AMIs:
```hcl
# In terraform.tfvars
cluster_version = "1.32"  # Changed from "1.33"
```

```yaml
# In karpenter-nodepool-default.yaml
amiFamily: AL2
amiSelectorTerms:
  - owner: "602401143452"
    name: "amazon-eks-node-1.32-*"
```

Then:
```bash
terraform destroy -auto-approve
terraform apply -auto-approve
```

**Future Path:**
For EKS 1.33+, must use AL2023:
```yaml
amiFamily: AL2023
amiSelectorTerms:
  - owner: "602401143452"
    name: "amazon-eks-node-al2023-x86_64-standard-1.33-*"
```

---

### 8. Karpenter Pod Not Scheduling (2 Replicas, 1 Node)

**Problem:**
```json
{
  "level":"ERROR",
  "message":"could not schedule pod",
  "Pod":{"name":"karpenter-5697769d6c-7lglp","namespace":"karpenter"},
  "error":"incompatible requirements, label \"role\" does not have known values"
}
```

**Symptoms:**
- One Karpenter pod Running
- One Karpenter pod Pending
- Karpenter logs showing scheduling errors
- NodePool showing "no nodepools found"

**Troubleshooting Steps:**
```bash
# Check Karpenter pods
kubectl get pods -n karpenter
# NAME                         READY   STATUS    RESTARTS   AGE
# karpenter-5697769d6c-7lglp   0/1     Pending   0          9m50s
# karpenter-5697769d6c-cdwct   1/1     Running   0          9m50s

# Check managed node labels
kubectl get nodes --show-labels | grep role
# Found: role=system label exists

# Check Karpenter deployment configuration
kubectl get deployment karpenter -n karpenter -o yaml | grep -A20 "affinity:"

# Found pod anti-affinity:
#   podAntiAffinity:
#     requiredDuringSchedulingIgnoredDuringExecution:
#       topologyKey: kubernetes.io/hostname
#       # This prevents 2 Karpenter pods on same node!

# Check replica count
kubectl get deployment karpenter -n karpenter
# READY   UP-TO-DATE   AVAILABLE
# 1/2     2            1           # 2 desired, only 1 running!
```

**Root Cause:**
- Karpenter Helm chart defaults to 2 replicas for HA
- Pod anti-affinity prevents both pods on same node
- Only 1 managed node available
- Second pod can't schedule

**Solution:** Scale down to 1 replica (appropriate for single managed node):
```bash
kubectl scale deployment karpenter -n karpenter --replicas=1
```

**Verification:**
```bash
kubectl get pods -n karpenter
# NAME                         READY   STATUS    RESTARTS   AGE
# karpenter-5697769d6c-cdwct   1/1     Running   0          10m

# Errors should stop in logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=20
```

**For Production:**
Keep 2 replicas but have 2 managed nodes:
```hcl
# In terraform.tfvars
node_desired_size = 2
node_min_size     = 2
```

---

### 9. Nodes Launched But Never Registered ⭐ CRITICAL ISSUE

**Problem:**
- NodeClaims status: `Unknown`
- Instances launched successfully
- Kubelet started successfully
- Bootstrap completed: `eks-bootstrap INFO: complete!`
- But nodes **never appeared** in `kubectl get nodes`

**Symptoms:**
```bash
kubectl get nodeclaims
# NAME            TYPE         CAPACITY    ZONE         NODE   READY     AGE
# default-kb85v   t3a.xlarge   on-demand   us-east-1a          Unknown   8m36s
# default-njzpq   t3a.xlarge   on-demand   us-east-1a          Unknown   8m36s

kubectl get nodes
# NAME                            STATUS   ROLES    AGE   VERSION
# ip-10-59-127-151.ec2.internal   Ready    <none>   24m   v1.32.9-eks-ecaa3a6
# (Only managed node, no Karpenter nodes!)
```

**Troubleshooting Steps:**

**Step 1: Check NodeClaim status**
```bash
kubectl describe nodeclaim default-kb85v | tail -30

# Output:
#   Conditions:
#     Type:    Initialized
#     Status:  Unknown
#     Message: Node not registered with cluster
#     Reason:  NodeNotFound
#
#   Provider ID: aws:///us-east-1a/i-01d1ff6c07a0e70f9
#   Image ID:    ami-071a9f2683c2da4bd
```

**Step 2: Verify instance is running**
```bash
aws ec2 describe-instances \
  --instance-ids i-01d1ff6c07a0e70f9 \
  --query 'Reservations[0].Instances[0].State.Name'

# Output: "running"
```

**Step 3: Check instance console output**
```bash
aws ec2 get-console-output \
  --instance-id i-01d1ff6c07a0e70f9 \
  --region us-east-1 \
  --latest

# Key findings:
# [OK] Started Kubernetes Kubelet.
# 2025-12-28T21:17:57+0000 [eks-bootstrap] INFO: complete!
# Cloud-init v. 19.3-46.amzn2.0.7 finished
# (No errors found!)
```

**Step 4: Check for kubelet errors**
```bash
aws ec2 get-console-output \
  --instance-id i-01d1ff6c07a0e70f9 \
  --region us-east-1 \
  --latest \
  | grep -i "kubelet\|error\|failed"

# No errors related to cluster communication
```

**Step 5: Check Karpenter logs**
```bash
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100

# Found:
# INFO: launched nodeclaim, provider-id: aws:///us-east-1a/i-01d1ff6c07a0e70f9
# (But no further updates about node registration)
```

**Step 6: Check security groups**
```bash
# Get cluster security group
terraform output cluster_security_group_id
# sg-02b9c955293332ba4

# Check cluster SG rules
aws ec2 describe-security-groups \
  --group-ids sg-02b9c955293332ba4 \
  --query 'SecurityGroups[0].IpPermissions'

# Check Karpenter node's security group
aws ec2 describe-instances \
  --instance-ids i-01d1ff6c07a0e70f9 \
  --query 'Reservations[0].Instances[0].SecurityGroups'

# Result: Security groups were correct!
```

**Step 7: Check IAM instance profile**
```bash
# Get instance profile
aws ec2 describe-instances \
  --instance-ids i-01d1ff6c07a0e70f9 \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn'

# arn:aws:iam::069057294951:instance-profile/aws-2026-eks_1976173924626587633

# Check role attached to profile
aws iam get-instance-profile \
  --instance-profile-name aws-2026-eks_1976173924626587633 \
  --query 'InstanceProfile.Roles[0].RoleName'

# aws-2026-eks-karpenter-node (Correct!)
```

**Step 8: Check aws-auth ConfigMap** ⭐ **FOUND THE ISSUE!**
```bash
kubectl get configmap aws-auth -n kube-system -o yaml
```

Output:
```yaml
apiVersion: v1
data:
  mapRoles: |
    - rolearn: arn:aws:iam::069057294951:role/aws-2026-eks-node-role
      groups:
      - system:bootstrappers
      - system:nodes
      username: system:node:{{EC2PrivateDNSName}}
kind: ConfigMap
...
```

**ROOT CAUSE IDENTIFIED:**
The aws-auth ConfigMap only had the **managed node group IAM role**, but was **missing the Karpenter node IAM role**!

Without the Karpenter node role in aws-auth:
1. Kubelet on Karpenter node starts successfully
2. Kubelet attempts to register with Kubernetes API server
3. API server checks aws-auth ConfigMap for authorization
4. IAM role `aws-2026-eks-karpenter-node` not found in aws-auth
5. API server **rejects** the node registration request
6. Node never appears in `kubectl get nodes`

**Solution:** Created aws-auth ConfigMap with both roles:

Created file: `k8s-manifests/aws-auth-cm.yaml`
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    ---
    - rolearn: arn:aws:iam::069057294951:role/aws-2026-eks-node-role
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
    - rolearn: arn:aws:iam::069057294951:role/aws-2026-eks-karpenter-node
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
```

Applied the fix:
```bash
kubectl apply -f k8s-manifests/aws-auth-cm.yaml
```

**Result:** 🎉 **SUCCESS!**
```bash
kubectl get nodes

# NAME                            STATUS     ROLES    AGE   VERSION
# ip-10-59-127-151.ec2.internal   Ready      <none>   28m   v1.32.9-eks-ecaa3a6
# ip-10-59-42-222.ec2.internal    NotReady   <none>   6s    v1.32.9-eks-ecaa3a6
# ip-10-59-51-73.ec2.internal     NotReady   <none>   7s    v1.32.9-eks-ecaa3a6

# Wait 30 seconds...

kubectl get nodes
# NAME                            STATUS   ROLES    AGE    VERSION
# ip-10-59-127-151.ec2.internal   Ready    <none>   30m    v1.32.9-eks-ecaa3a6
# ip-10-59-42-222.ec2.internal    Ready    <none>   101s   v1.32.9-eks-ecaa3a6
# ip-10-59-51-73.ec2.internal     Ready    <none>   102s   v1.32.9-eks-ecaa3a6

# Check nodeclaims
kubectl get nodeclaims
# NAME            TYPE         CAPACITY    ZONE         NODE                           READY   AGE
# default-kb85v   t3a.xlarge   on-demand   us-east-1a   ip-10-59-51-73.ec2.internal    True    14m
# default-njzpq   t3a.xlarge   on-demand   us-east-1a   ip-10-59-42-222.ec2.internal   True    14m

# Check pods
kubectl get pods -o wide
# NAME                       NODE
# inflate-5cf78d58f6-9snnr   ip-10-59-42-222.ec2.internal   Running
# inflate-5cf78d58f6-dr99n   ip-10-59-51-73.ec2.internal    Running
# inflate-5cf78d58f6-hkh9w   ip-10-59-42-222.ec2.internal   Running
# inflate-5cf78d58f6-jdf7w   ip-10-59-42-222.ec2.internal   Running
# inflate-5cf78d58f6-qflgj   ip-10-59-51-73.ec2.internal    Running
```

**Verification:**
All 5 inflate pods running on Karpenter-provisioned nodes! ✅

**Key Learning:**
The aws-auth ConfigMap is **critical** for Karpenter. It must include:
1. Managed node group IAM role (for system nodes)
2. **Karpenter node IAM role** (for Karpenter-provisioned nodes)

Without both, nodes cannot register with the cluster.

---

### 10. Expired AWS Credentials

**Problem:**
```
An error occurred (ExpiredToken) when calling the GetCallerIdentity operation:
The security token included in the request is expired
```

**Symptoms:**
- AWS CLI commands failing
- terraform commands failing

**Troubleshooting Steps:**
```bash
# Test credentials
aws sts get-caller-identity
```

**Solution:**
```bash
source ./scripts/env_setup.sh
```

**Verification:**
```bash
aws sts get-caller-identity
# {
#     "UserId": "AIDARAFBCWJTZVOPTBGLQ",
#     "Account": "069057294951",
#     "Arn": "arn:aws:iam::069057294951:user/terraform-user"
# }
```

---

### 11. kubectl Connection Issues

**Problem:**
```
The connection to the server localhost:42169 was refused -
did you specify the right host or port?
```

**Symptoms:**
- kubectl commands failing
- Connection refused errors

**Troubleshooting Steps:**
```bash
# Check KUBECONFIG
echo $KUBECONFIG
# (empty or wrong path)

# Check if kubeconfig file exists
ls -la /Users/kwang04/my-projects/aws-2026/tmp/kubeconfig
```

**Solution:**
```bash
# Rebuild kubeconfig
./scripts/build-temp-kubeconfig.sh

# Set KUBECONFIG environment variable
export KUBECONFIG=/Users/kwang04/my-projects/aws-2026/tmp/kubeconfig

# Source credentials
source ./scripts/env_setup.sh
```

**Verification:**
```bash
kubectl get nodes
# Should work now
```

**Pro Tip:**
Add to your shell profile to persist:
```bash
# Add to ~/.zshrc or ~/.bashrc
export KUBECONFIG=/Users/kwang04/my-projects/aws-2026/tmp/kubeconfig
```

---

## Key Diagnostic Commands Reference

### Check Karpenter Resources
```bash
# Nodes and nodeclaims
kubectl get nodes
kubectl get nodes -o wide
kubectl get nodeclaims
kubectl get nodeclaims -o wide
kubectl describe nodeclaim <name>

# NodePools and EC2NodeClasses
kubectl get nodepool
kubectl get nodepool default -o yaml
kubectl describe nodepool default
kubectl get ec2nodeclass
kubectl get ec2nodeclass default -o yaml
kubectl get ec2nodeclass default -o jsonpath='{.status.amis}' | jq .

# Karpenter controller
kubectl get pods -n karpenter
kubectl get deployment karpenter -n karpenter
kubectl describe pod -n karpenter <pod-name>

# ConfigMaps
kubectl get configmap aws-auth -n kube-system -o yaml

# CRDs
kubectl get crd | grep karpenter
kubectl get crd nodeclaims.karpenter.sh -o yaml
kubectl get crd nodepools.karpenter.sh -o yaml
kubectl get crd ec2nodeclasses.karpenter.k8s.aws -o yaml
```

### Check Logs
```bash
# Karpenter controller logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --follow
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | grep -i error

# Instance console output
aws ec2 get-console-output --instance-id <id> --region us-east-1 --latest
aws ec2 get-console-output --instance-id <id> --region us-east-1 | grep -i error
aws ec2 get-console-output --instance-id <id> --region us-east-1 | grep -i kubelet
```

### Check AWS Resources
```bash
# EC2 instances
aws ec2 describe-instances --instance-ids <id>
aws ec2 describe-instances --instance-ids <id> \
  --query 'Reservations[0].Instances[0].[State.Name,IamInstanceProfile.Arn,SecurityGroups[*].GroupId]'

# Security groups
aws ec2 describe-security-groups --group-ids <sg-id>
aws ec2 describe-security-groups --group-ids <sg-id> \
  --query 'SecurityGroups[0].IpPermissions'

# AMIs
aws ec2 describe-images \
  --owners 602401143452 \
  --filters "Name=name,Values=amazon-eks-node-1.32-*" \
  --query 'Images[*].[ImageId,Name,CreationDate]'

# IAM
aws iam get-instance-profile --instance-profile-name <name>
aws iam get-role --role-name <name>
aws sts get-caller-identity
```

### Check Terraform
```bash
# Outputs
terraform output
terraform output cluster_endpoint
terraform output karpenter_controller_role_arn

# State
terraform state list
terraform state show <resource>

# Validate
terraform validate
terraform plan
```

---

## Final Working Configuration

### Infrastructure
- **EKS Version:** 1.32
- **AWS Region:** us-east-1
- **Availability Zones:** us-east-1a, us-east-1b

### Karpenter
- **Version:** v1.7.4 (latest as of Dec 2024)
- **API Version:** v1 (not v1beta1)
- **Replicas:** 1 (matching single managed node)

### Nodes
- **Managed Nodes:** 1 x t3.medium
  - Label: `role=system`
  - Taint: `CriticalAddonsOnly=true:NoSchedule`
  - Runs: Karpenter, CoreDNS, kube-proxy
- **Karpenter Nodes:** 2 x t3a.xlarge (on-demand)
  - AMI Family: AL2 (Amazon Linux 2)
  - Auto-provisioned based on pod requirements

### Key Files

**Terraform:**
- `terraform.tfvars` - Cluster version 1.32
- `karpenter.tf` - IAM roles, policies, SQS, EventBridge
- `eks-nodes.tf` - Managed node with taint/labels
- `outputs.tf` - Karpenter outputs for Helm

**Kubernetes Manifests:**
- `k8s-manifests/aws-auth-cm.yaml` - **Critical:** Both node roles
- `k8s-manifests/karpenter-nodepool-default.yaml` - NodePool + EC2NodeClass (AL2, v1 API)
- `k8s-manifests/test-deployment.yaml` - Test workload

**Scripts:**
- `scripts/install-karpenter.sh` - Helm install Karpenter v1.7.4
- `scripts/env_setup.sh` - AWS credentials
- `scripts/build-temp-kubeconfig.sh` - Generate kubeconfig

### NodePool Configuration
```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["t3", "t3a"]
  limits:
    cpu: "100"
    memory: "200Gi"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  amiSelectorTerms:
    - owner: "602401143452"  # AWS EKS AMI account
      name: "amazon-eks-node-1.32-*"
  role: "aws-2026-eks-karpenter-node"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "aws-2026-eks"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "aws-2026-eks"
```

### aws-auth ConfigMap (Critical!)
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    ---
    - rolearn: arn:aws:iam::069057294951:role/aws-2026-eks-node-role
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
    - rolearn: arn:aws:iam::069057294951:role/aws-2026-eks-karpenter-node
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
```

---

## Lessons Learned

### 1. aws-auth ConfigMap is Critical
**The most important lesson:** Karpenter-provisioned nodes need their IAM role in the aws-auth ConfigMap. Without it, nodes will launch successfully but never register with the cluster.

Always verify:
```bash
kubectl get configmap aws-auth -n kube-system -o yaml
```

### 2. AL2023 Requires Different Bootstrap Process
AL2023 uses `nodeadm` instead of `/etc/eks/bootstrap.sh`. The NodeConfig format is correct and expected.

### 3. AWS Stopped Publishing AL2 AMIs
As of November 26, 2025, AWS no longer publishes AL2 AMIs. EKS 1.33+ only has AL2023.

### 4. AMI Owner Filter is Important
Always specify `owner: "602401143452"` to avoid selecting custom AMIs in your account.

### 5. Karpenter v1 API Has Stricter Validation
v1 API requires more explicit configuration than v1beta1:
- Must specify `group` and `kind` in nodeClassRef
- Different consolidation policy values
- amiSelectorTerms is required

### 6. Pod Anti-Affinity Needs Enough Nodes
Karpenter's default 2 replicas with pod anti-affinity requires 2 nodes. Scale to 1 replica if only 1 managed node.

### 7. Console Output is Invaluable
EC2 console output shows the actual bootstrap process:
```bash
aws ec2 get-console-output --instance-id <id> --region us-east-1
```

### 8. Check Both Terraform AND Kubernetes State
Issues can exist at multiple layers:
- Terraform: IAM roles, security groups, subnets
- Kubernetes: aws-auth, node labels, taints
- AWS: EC2 instances, AMIs, networking

### 9. Karpenter Permissions Evolve
Newer versions (like v1.7.4) may require additional IAM permissions (like `iam:ListInstanceProfiles`).

### 10. Work Incrementally
Test each component:
1. Cluster creation
2. Karpenter installation
3. NodePool configuration
4. Node provisioning
5. Pod scheduling

Don't skip steps!

---

## Quick Reference: Common Issues

| Symptom | Likely Cause | Check |
|---------|--------------|-------|
| Nodes launched but not registering | Missing aws-auth role | `kubectl get cm aws-auth -n kube-system -o yaml` |
| AMISelector did not match | Wrong AMI name/owner | `kubectl get ec2nodeclass -o yaml` |
| Karpenter pod pending | Not enough nodes for replicas | `kubectl get pods -n karpenter` |
| CRD conversion errors | Wrong webhook config | `kubectl get crd <name> -o yaml` |
| Access denied errors | Missing IAM permission | `kubectl logs -n karpenter` |
| Spot instance errors | No service-linked role | Use on-demand or create role |
| NodePool not ready | EC2NodeClass not ready | `kubectl describe nodepool` |
| kubectl connection refused | Wrong KUBECONFIG | `echo $KUBECONFIG` |
| AWS CLI errors | Expired credentials | `aws sts get-caller-identity` |

---

## Future: EKS 1.33 + AL2023 Plan

Tomorrow's plan to try AL2023 with EKS 1.33:

1. Update `terraform.tfvars`:
   ```hcl
   cluster_version = "1.33"
   ```

2. Update `karpenter-nodepool-default.yaml`:
   ```yaml
   amiFamily: AL2023
   amiSelectorTerms:
     - owner: "602401143452"
       name: "amazon-eks-node-al2023-x86_64-standard-1.33-*"
   ```

3. Apply changes:
   ```bash
   terraform apply
   ./scripts/install-karpenter.sh
   kubectl scale deployment karpenter -n karpenter --replicas=1
   kubectl apply -f k8s-manifests/aws-auth-cm.yaml  # Critical!
   kubectl apply -f k8s-manifests/karpenter-nodepool-default.yaml
   ```

With the aws-auth fix and proper understanding of AL2023's `nodeadm` process, this should work!

---

## Additional Resources

- [Karpenter Documentation](https://karpenter.sh/)
- [Karpenter v1.7.4 Release Notes](https://github.com/aws/karpenter-provider-aws/releases/tag/v1.0.7)
- [AL2023 for EKS](https://docs.aws.amazon.com/eks/latest/userguide/al2023.html)
- [EKS Best Practices - Karpenter](https://aws.github.io/aws-eks-best-practices/karpenter/)
- [aws-auth ConfigMap](https://docs.aws.amazon.com/eks/latest/userguide/add-user-role.html)

---

**Document Version:** 1.0
**Date:** December 28, 2025
**Cluster:** aws-2026-eks (EKS 1.32)
**Karpenter Version:** v1.7.4
