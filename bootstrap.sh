#!/bin/bash
# Creates the kind cluster (if needed), deploys prerequisites and the todoapp helm chart.
# Run it from the repository root. Safe to run more than once.
set -euo pipefail

CLUSTER="todo"
CHART_DIR="helm-chart/todoapp"
RELEASE="todoapp"

# 0. Create the kind cluster from cluster.yml (skipped if it already exists)
if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config cluster.yml --name "$CLUSTER"
fi
kubectl config use-context "kind-$CLUSTER"

# Safety guard: never deploy to anything but a kind cluster
CONTEXT="$(kubectl config current-context)"
if [[ "$CONTEXT" != kind-* ]]; then
  echo "Refusing to run: current kubectl context is '$CONTEXT', expected a kind-* context" >&2
  exit 1
fi

# 1. Inspect node labels and taints, then taint the MySQL nodes so that
#    only pods with a matching toleration land there
kubectl get nodes --show-labels
kubectl get nodes -o custom-columns="NAME:.metadata.name,TAINTS:.spec.taints[*].key"
kubectl taint nodes -l app=mysql app=mysql:NoSchedule --overwrite
kubectl get nodes -o custom-columns="NAME:.metadata.name,TAINTS:.spec.taints[*].key"

# 2. Ingress controller (kind flavour). Must be ready before the chart creates an Ingress,
#    otherwise the admission webhook rejects it.
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

# 3. Metrics server (required by the HPA). kind kubelets use self-signed certs,
#    so --kubelet-insecure-tls is needed.
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
if ! kubectl get deployment metrics-server -n kube-system \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-insecure-tls'; then
  kubectl patch deployment metrics-server -n kube-system --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
kubectl rollout status deployment/metrics-server -n kube-system --timeout=300s

# 4. Deploy the todoapp chart (the mysql sub-chart is deployed together with it)
helm dependency update "$CHART_DIR"
helm upgrade --install "$RELEASE" "$CHART_DIR" -f "$CHART_DIR/values.yaml" --wait --timeout 10m

# 5. Save the result to output.log in the repository root
kubectl get all,cm,secret,ing -A | tee output.log
