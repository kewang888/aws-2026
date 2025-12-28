kubectl get configmap aws-auth -n kube-system -o yaml

./scripts/build-temp-kubeconfig.sh
export KUBECONFIG=/Users/kwang04/my-projects/aws-2026/tmp/kubeconfig
source ./scripts/env_setup.sh


./scripts/install-karpenter.sh

kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter