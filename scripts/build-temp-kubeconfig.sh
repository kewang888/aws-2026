#!/bin/bash

set -e  # Enable exit on error and command tracing

echo "building a temp kubeconfig..."

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)

source "$PROJECT_ROOT"/scripts/env_setup.sh

apiServerEndpoint=$(aws eks describe-cluster --name "aws-2026-eks" --query "cluster.endpoint" --output text)
echo "apiServerEndpoint: $apiServerEndpoint"

clusterCertificateAuthority=$(aws eks describe-cluster --name "aws-2026-eks" --query "cluster.certificateAuthority.data" --output text)
echo "clusterCertificateAuthority: $clusterCertificateAuthority"

kubeconfigTemplate="my-kubeconfig"
cp "$PROJECT_ROOT"/eks/"$kubeconfigTemplate" "$PROJECT_ROOT"/tmp/"kubeconfig"

yq e ".clusters[0].cluster.certificate-authority-data=\"${clusterCertificateAuthority}\"" -i "$PROJECT_ROOT"/tmp/"kubeconfig"
yq e ".clusters[0].cluster.server=\"${apiServerEndpoint}\"" -i "$PROJECT_ROOT"/tmp/"kubeconfig"

cat "$PROJECT_ROOT"/tmp/"kubeconfig"

export KUBECONFIG=$PROJECT_ROOT/tmp/"kubeconfig"