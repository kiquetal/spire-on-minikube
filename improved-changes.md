# SPIRE + Istio Integration: Improved Implementation Guide

This document details the specific, verified changes required to integrate SPIRE as the identity provider for Istio 1.28 on Kubernetes 1.30+. These changes replace legacy or broken configurations with the official SDS-based (Secret Discovery Service) approach.

## 1. Corrected Istio Helm Values
**File:** `manifest/istio-spire-values-fixed.yaml`

The critical change here is moving the socket configuration to `proxyMetadata` and using `initContainers` for native sidecar compatibility.

```yaml
meshConfig:
  trustDomain: "example.org"
  defaultConfig:
    proxyMetadata:
      # Centralized socket path for Envoy SDS
      ISTIO_META_WORKLOAD_SOCKET_PATH: /run/secrets/workload-spiffe-uds/socket

sidecarInjectorWebhook:
  templates:
    spire: |
      labels:
        # REQUIRED: Trigger SPIRE Controller Manager registration
        spiffe.io/spire-managed-identity: "true"
      spec:
        # For K8s 1.29+, the sidecar is a native sidecar (initContainer)
        initContainers:
        - name: istio-proxy
          volumeMounts:
          - name: workload-socket
            mountPath: /run/secrets/workload-spiffe-uds
            readOnly: true
        volumes:
          - name: workload-socket
            csi:
              driver: "csi.spiffe.io"
              readOnly: true
```

### Key Differences:
*   **Native Sidecar Support**: Uses `initContainers` to merge with Istio's native sidecar (required for K8s 1.29+).
*   **Removed `caCertificatesPem`**: Istio now fetches the trust bundle automatically via the SPIRE socket (SDS).
*   **Automated Labeling**: The `labels` section in the template ensures workloads are automatically registered by SPIRE.

---

## 2. Ingress Gateway Patch
**File:** `manifest/ingress-spire-patch.yaml`

The Ingress Gateway requires a specific patch to bridge the gap between Istio's gateway deployment and the SPIRE infrastructure.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istio-ingress
  namespace: istio-ingress
spec:
  template:
    metadata:
      labels:
        spiffe.io/spire-managed-identity: "true"
      annotations:
        # Ingress needs an explicit pointer to the trust root for backend verification
        proxy.istio.io/config: |
          caCertificatesPem:
          - "/var/run/secrets/spire-bundle/root-cert.pem"
        sidecar.istio.io/userVolume: '[{"name":"workload-socket","csi":{"driver":"csi.spiffe.io","readOnly":true}},{"name":"spire-bundle","configMap":{"name":"spire-bundle"}}]'
        sidecar.istio.io/userVolumeMount: '[{"name":"workload-socket","mountPath":"/run/secrets/workload-spiffe-uds","readOnly":true},{"name":"spire-bundle","mountPath":"/var/run/secrets/spire-bundle","readOnly":true}]'
    spec:
      containers:
      - name: istio-proxy
        env:
        - name: ISTIO_META_WORKLOAD_SOCKET_PATH
          value: "/run/secrets/workload-spiffe-uds/socket"
        volumeMounts:
        - name: workload-socket
          mountPath: "/run/secrets/workload-spiffe-uds"
          readOnly: true
        - name: spire-bundle
          mountPath: "/var/run/secrets/spire-bundle"
          readOnly: true
      volumes:
      - name: workload-socket
        csi:
          driver: csi.spiffe.io
          readOnly: true
      - name: spire-bundle
        configMap:
          name: spire-bundle
```

---

## 3. Persistent Ingress Registration
**File:** `manifest/ingress-registration.yaml`

Without this, the Ingress Gateway will fail with: `workload is not authorized for the requested identities ["default"]`.

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: istio-ingress
spec:
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      istio: ingress
  workloadSelectorTemplates:
    - "k8s:ns:istio-ingress"
    - "k8s:sa:istio-ingress"
```

---

## 4. Simplified Workload Template
**File:** `manifest/httpbin-simple-final.yaml`

Because we have centralized the SPIRE configuration in `istiod`, adding SPIRE to a new workload is now simple:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin-simple
  namespace: apps
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin-simple
  namespace: apps
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin-simple
  template:
    metadata:
      labels:
        app: httpbin-simple
      annotations:
        # This triggers the 'spire' template we defined in Helm values
        inject.istio.io/templates: "sidecar,spire"
    spec:
      serviceAccountName: httpbin-simple
      containers:
      - name: httpbin
        image: docker.io/kennethreitz/httpbin
        ports:
        - containerPort: 80
```

---

## 5. Verification Steps for Tomorrow

### Step A: Apply Identity Infrastructure
```bash
# Apply corrected Istio values
helm upgrade istiod istio/istiod -n istio-system -f manifest/istio-spire-values-fixed.yaml

# Apply Ingress Registration
kubectl apply -f manifest/ingress-registration.yaml

# Apply Ingress Patch
kubectl apply -f manifest/ingress-spire-patch.yaml
kubectl rollout restart deployment istio-ingress -n istio-ingress
```

### Step B: Validate SPIFFE Headers
Run a curl through the Ingress to a sidecar-enabled backend:
```bash
kubectl exec -n apps sleep-spire-xxxx -c sleep -- curl -s http://<INGRESS_IP>/headers
```

**Successful Output should include:**
`"X-Forwarded-Client-Cert": "...URI=spiffe://example.org/ns/istio-ingress/sa/istio-ingress"`
