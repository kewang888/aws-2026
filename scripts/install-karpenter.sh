#!/bin/bash
set -e

CLUSTER_NAME="aws-2026-eks"
AWS_REGION="us-east-1"
KARPENTER_VERSION="1.7.4"

echo "Installing Karpenter ${KARPENTER_VERSION}..."

# Get outputs from Terraform
KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn)
CLUSTER_ENDPOINT=$(terraform output -raw cluster_endpoint)
INTERRUPTION_QUEUE=$(terraform output -raw karpenter_interruption_queue_name)

echo "Karpenter Controller Role ARN: ${KARPENTER_ROLE_ARN}"
echo "Cluster Endpoint: ${CLUSTER_ENDPOINT}"
echo "Interruption Queue: ${INTERRUPTION_QUEUE}"

# Update kubeconfig
echo "Updating kubeconfig..."
aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME}

# Logout and login to ECR public registry
echo "Logging in to ECR public..."
aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws

# Install Karpenter
echo "Installing Karpenter via Helm..."
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace karpenter \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "settings.interruptionQueue=${INTERRUPTION_QUEUE}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_ROLE_ARN}" \
  --set "controller.resources.requests.cpu=100m" \
  --set "controller.resources.requests.memory=256Mi" \
  --set "controller.resources.limits.cpu=1000m" \
  --set "controller.resources.limits.memory=1Gi" \
  --set "replicas=2" \
  --set "tolerations[0].key=CriticalAddonsOnly" \
  --set "tolerations[0].operator=Exists" \
  --set "tolerations[0].effect=NoSchedule" \
  --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=role" \
  --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In" \
  --set "affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=system" \
  --wait

echo ""
echo "Karpenter installation complete!"
echo ""
echo "Verify with:"
echo "  kubectl get pods -n karpenter"
echo "  kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter"
echo ""
echo "Next steps:"
echo "  1. Apply NodePool: kubectl apply -f k8s-manifests/karpenter-nodepool-default.yaml"
echo "  2. Test with: kubectl apply -f k8s-manifests/test-deployment.yaml"
echo "  3. Scale up: kubectl scale deployment inflate --replicas=5"
echo "  4. Watch nodes: kubectl get nodes --watch"
