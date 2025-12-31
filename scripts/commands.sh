#!/bin/bash

./scripts/build-temp-kubeconfig.sh
export KUBECONFIG=/Users/kwang04/my-projects/aws-2026/tmp/kubeconfig
source ./scripts/env_setup.sh

./scripts/install-karpenter.sh

kubectl apply -f k8s-manifests/aws-auth-cm.yaml
kubectl apply -f k8s-manifests/karpenter-nodepool-default.yaml
kubectl apply -f k8s-manifests/test-deployment.yaml
kubectl scale deployment inflate --replicas=5


#kubectl get configmap aws-auth -n kube-system -o yaml
#kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter
#terraform destroy -auto-approve