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

We will use Helm to install Istio components (Base, Istiod, and Ingress Gateway) separately.

```bash
# Add Istio Helm repo
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# 1. Install Istio Base (CRDs)
helm install istio-base istio/base -n istio-system --create-namespace

# 2. Install Istiod (Control Plane) with SPIRE integration
helm install istiod istio/istiod -n istio-system --wait -f manifest/istio-spire-values.yaml

### Understanding `manifest/istio-spire-values.yaml`

The values provided to Helm configure Istio to integrate natively with SPIRE:

- **Global Trust Root**: `meshConfig.defaultConfig.caCertificatesPem` ensures every injected sidecar knows to trust the SPIRE root certificate for mTLS.
- **Custom Sidecar Template**: `sidecarInjectorWebhook.templates.spire` defines a named template that:
    - Mounts the **SPIRE Agent socket** via the CSI driver.
    - Mounts the **SPIRE Bundle** (root CA) from a ConfigMap.
    - Sets `ISTIO_META_WORKLOAD_SOCKET_PATH` so the Envoy proxy knows where to find the socket.

To use this template, workloads must be annotated with `inject.istio.io/templates: "sidecar,spire"`.

# 3. Install Istio Ingress Gateway
helm install istio-ingress istio/gateway -n istio-ingress --create-namespace --wait

# 4. Patch Ingress Gateway for SPIRE Trust
kubectl apply -f manifest/ingress-spire-patch.yaml

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
helm upgrade --install spire-crds spiffe/spire-crds \
  --namespace spire-server \
  --create-namespace \
  --version 0.4.0 \
  --wait

# Install SPIRE (Server and Agent) with CSI driver enabled
helm upgrade --install spire spiffe/spire \
  --namespace spire-server \
  --version 0.26.0 \
  -f manifest/spire-values.yaml \
  --wait
```

### Register Cluster SPIFFE ID
```bash
kubectl apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: istio-ingress
spec:
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  workloadSelectorTemplates:
    - "k8s:ns:istio-ingress"
    - "k8s:sa:istio-ingress"
EOF
```

### Register Cluster SPIFFE ID for Sidecars (Auto-registration)
This will auto-register any pod with the `spiffe.io/spire-managed-identity: "true"` label in the `apps` namespace.

```bash
kubectl apply -f - <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: istio-sidecar-reg
spec:
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      spiffe.io/spire-managed-identity: "true"
  workloadSelectorTemplates:
    - "k8s:ns:apps"
EOF
```

## Step 4: Verify Installation

### Check Pods
```bash
kubectl get pods -n istio-system
kubectl get pods -n istio-ingress
kubectl get pods -n spire-server
```

## Step 5: Deploy HttpBin (SPIRE Enabled)

Deploy the `httpbin` sample application. This manifest includes the necessary annotations and Envoy filters to trust SPIRE.

```bash
# 1. Create apps namespace and label it
kubectl create ns apps || true
kubectl label namespace apps istio-injection=enabled --overwrite

# 2. Deploy httpbin
kubectl apply -f manifest/httpbin-spire.yaml

> **Note**: `manifest/httpbin-spire.yaml` uses the `inject.istio.io/templates: "sidecar,spire"` annotation to apply the SPIRE template configured in Step 2.

# 3. Verify SPIRE Registration
# With ClusterSPIFFEID, registration is automatic. Check the SPIRE server:
kubectl exec -n spire-server spire-server-0 -- /opt/spire/bin/spire-server entry show -spiffeID spiffe://example.org/ns/apps/sa/httpbin
```

## Step 6: Test Sleep Client

```bash
kubectl apply -f manifest/sleep-spire.yaml
```



### Checking jwt and testing exchange


     kubectl exec -n apps debug-spire -c tools -- curl -X POST -s -X POST http://keycloak.spire-server.svc:8080/realms/spire-demo/protocol/openid-connect/token \
	    -d "grant_type=client_credentials" \
	    -d "client_id=spiffe://example.org/ns/apps/sa/debug-spire" \
	    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe" \
	    -d "client_assertion=eyJhbGciOiJSUzI1NiIsImtpZCI6IkhLNXgwU0h3YUFqOXd3bFpNcUJmUkFkekFmRVhFY3hnIiwidHlwIjoiSldUIn0.eyJhdWQiOlsiaHR0cDovL2tleWNsb2FrLnNwaXJlLXNlcnZlci5zdmM6ODA4MC9yZWFsbXMvc3BpcmUtZGVtbyJdLCJleHAiOjE3NzAzMDc3MzUsImlhdCI6MTc3MDMwNDEzNSwiaXNzIjoiaHR0cHM6Ly9vaWRjLWRpc2NvdmVyeS5leGFtcGxlLm9yZyIsInN1YiI6InNwaWZmZTovL2V4YW1wbGUub3JnL25zL2FwcHMvc2EvZGVidWctc3BpcmUifQ.qyYeiiiqOY58G5Wnb34kQPqzTxAaeOYDiHY5YqDyA1TyF9Hfp1W93oHVapZgx55H7K2_mgU33vUN8lWW3z7Qkp_xKqYchcMgRkIrBcsspoNyqpwF6hj2WvovRdF9bXxvjvJhCMqf5sfjs3sVs0-GDSdtH0USbbvJqUszeyIh4UUTesS8qM5RiWvA_GVV_DCG6KjGctIaw5FQbymyUF4-nNmSE7dhmum-HXAkX9j8vCs52Bp8O2i3t-hRvQFp__Er--LaF8kzSlt41tPtix1lv5Pag1hpJ_SpCu4ZCuyWMCSYMFC9np14Wh12y__rEbb0PLppRJuT5-SFZyAXjWOPSQ" | jq .



kubectl exec -n apps debug-spire -c tools -- /tmp/spire-agent api fetch jwt \
       -audience "spire" \
       -socketPath /run/secrets/workload-spiffe-uds/spire-agent.sock 
  
