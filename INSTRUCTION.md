# How to validate the changes

## Prerequisites

- Docker (running), `kind`, `kubectl`, `helm`
- Free ports `80`, `443`, `30007`, `30008` on the host (they are published by the kind control-plane node)
- A Bash shell (Git Bash on Windows)

## 1. Create the cluster

```bash
kind create cluster --config cluster.yml --name todo
kubectl config use-context kind-todo
```

Inspect node labels and taints (the nodes labeled `app=mysql` get tainted in step 2):

```bash
kubectl get nodes --show-labels
kubectl get nodes -o custom-columns="NAME:.metadata.name,TAINTS:.spec.taints[*].key"
```

## 2. Deploy

```bash
bash bootstrap.sh
```

The script (it refuses to run unless the current context is a `kind-*` one):

1. taints nodes labeled `app=mysql` with `app=mysql:NoSchedule`;
2. installs the ingress-nginx controller (kind flavour) and waits for it;
3. installs metrics-server (patched with `--kubelet-insecure-tls`) so that the HPA gets metrics;
4. runs `helm dependency update` and `helm upgrade --install todoapp .infrastructure/helm-chart/todoapp`
   (the `mysql` sub-chart in `charts/mysql` is deployed together with it);
5. prints `kubectl get all,cm,secret,ing -A`.

The first run can take several minutes because of image pulls.

## 3. Verify

Chart checks (the same ones the CI workflow runs):

```bash
helm lint .infrastructure/helm-chart/todoapp
helm template .infrastructure/helm-chart/todoapp -f .infrastructure/helm-chart/todoapp/values.yaml
```

Cluster state:

```bash
kubectl get pods -n mysql -o wide      # mysql-0 and mysql-1, Running, on the nodes labeled app=mysql
kubectl get pods -n todoapp -o wide    # 2 x todoapp, Running
kubectl get hpa,ing -n todoapp         # HPA "todoapp" with real CPU/memory targets, Ingress "todoapp-ingress"
kubectl get all,cm,secret,ing -A > output.log
python .github/workflows/scripts/validate-output.py   # every line must be True
```

## 4. Check that everything is driven by `values.yaml`

Everything below is controlled from `.infrastructure/helm-chart/todoapp/values.yaml`
(and `.infrastructure/helm-chart/todoapp/charts/mysql/values.yaml` for MySQL):
namespace, secrets (rendered with `range`, also used as env variables with `range`),
resources, RollingUpdate parameters, image repository/tag, node affinity, HPA limits and
CPU/memory targets, PV/PVC size, ServiceAccount name (Deployment and all RBAC objects);
for MySQL also replicas, storage, affinity and tolerations.

Example: render with a different replica count and check the result.

```bash
helm template .infrastructure/helm-chart/todoapp --set mysql.replicas=3 | grep -n "replicas"
```

(`helm template` with a changed value is the quickest way to prove a parameter is wired to `values.yaml`.)

## 5. Clean up

```bash
helm uninstall todoapp
kind delete cluster --name todo
```
