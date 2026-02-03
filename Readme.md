# SPIRE on Minikube + Istio

This guide outlines the steps to set up a Minikube cluster with Kubernetes 1.30+, install Istio, and install SPIRE to issue SPIFFE IDs.

## Prerequisites

- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- [Kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Istioctl](https://istio.io/latest/docs/setup/getting-started/#download)

## Step 1: Start Minikube

Start Minikube with Kubernetes version 1.30.0 (or newer). We allocate sufficient resources.

```bash
minikube start --kubernetes-version=v1.30.0 --cpus=4 --memory=8192 --driver=docker
```

## Step 2: Install Istio

We will use Helm to install Istio components (Base, Istiod, and Ingress Gateway) separately, which is the recommended production approach.

```bash
# Add Istio Helm repo
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# 1. Install Istio Base (CRDs)
helm install istio-base istio/base -n istio-system --create-namespace

# 2. Install Istiod (Control Plane)
helm install istiod istio/istiod -n istio-system --wait

# 3. Install Istio Ingress Gateway
helm install istio-ingress istio/gateway -n istio-ingress --create-namespace --wait

# Label the default namespace for injection
kubectl label namespace default istio-injection=enabled
```

## Step 3: Install SPIRE

We will use the official SPIRE Helm charts to install the SPIRE Server and Agent.

```bash
# Add the SPIFFE Helm repo
helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/
helm repo update

# Install SPIRE CRDs
helm install spire-crds spiffe/spire-crds --namespace spire-server --create-namespace

# Install SPIRE (Server and Agent) with CSI driver enabled
helm install spire spiffe/spire \
  --namespace spire-server \
  --set spiffe-csi-driver.enabled=true \
  --set spiffe-csi-driver.csiDriverSidecar.enable=true \
  --set spiffe-csi-driver.healthChecker.enabled=true \
  --set spiffe-csi-driver.approveCSR=true
```

## Step 4: Verify Installation

### Check Pods
```bash
kubectl get pods -n istio-system
kubectl get pods -n istio-ingress
kubectl get pods -n spire-server
```

### Create a Registration Entry
To allow a workload to obtain a SPIFFE ID, create an entry in the SPIRE Server. This example targets a specific workload with the label `app: frontend`.

```bash
# Get SPIRE Server pod
SPIRE_SERVER=$(kubectl get pods -n spire-server -l app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}')

# Example: Create an entry for the 'frontend' workload
# Requires: namespace 'default', service account 'default', AND pod label 'app: frontend'
kubectl exec -n spire-server $SPIRE_SERVER -- \
  /opt/spire/bin/spire-server entry create \
  -spiffeID spiffe://example.org/ns/default/sa/default/frontend \
  -parentID spiffe://example.org/ns/spire-server/sa/spire-agent \
  -selector k8s:ns:default \
  -selector k8s:sa:default \
  -selector k8s:pod-label:app:frontend
```

### Understanding SPIRE Selectors
SPIRE uses **selectors** to attest (verify) the identity of a workload. The `k8s` prefix indicates the [Kubernetes Workload Attestor](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_workloadattestor_k8s.md).

Common selectors include:

| Selector | Description | Example |
| :--- | :--- | :--- |
| `k8s:ns` | Namespace of the pod | `k8s:ns:default` |
| `k8s:sa` | Service Account of the pod | `k8s:sa:my-sa` |
| `k8s:pod-label` | Label on the Pod | `k8s:pod-label:app:frontend` |
| `k8s:container-name` | Name of the container | `k8s:container-name:istio-proxy` |
| `k8s:node-name` | Node where the pod runs | `k8s:node-name:minikube` |