# SPIRE Integration for Istio Ingress Gateway

The `final-ingress-patch.yaml` fixed the Ingress Gateway connectivity by bridging the gap between SPIRE identity issuance and Istio's trust validation.

## Key Differences & Why It Works

### 1. Explicit Trust Root (`caCertificatesPem`)
The most critical addition was the `proxy.istio.io/config` annotation. Previous attempts provided the SPIRE socket but didn't tell Envoy to trust the SPIRE CA. This configuration explicitly points Envoy to the SPIRE root certificate for verifying backend workloads.

### 2. SPIRE Bundle Mounting
The patch adds a volume for the `spire-bundle` ConfigMap. Without the physical `root-cert.pem` file mounted at `/var/run/secrets/spire-bundle/`, the gateway has no way to verify the identities of the services it routes to.

### 3. Explicit Workload Socket Path
Setting `ISTIO_META_WORKLOAD_SOCKET_PATH` ensures the `istio-proxy` knows exactly where to find the SPIRE Workload API. While this is often automated for sidecars, Ingress Gateways frequently require this explicit environment variable to override default Istio behavior.

### 4. Configuration Redundancy
The patch uses both annotations and direct container volume mounts. This ensures that even if the Istio Sidecar Injector doesn't perfectly handle the Gateway deployment, the necessary SPIRE infrastructure is guaranteed to be present.

## The Working Configuration (`final-ingress-patch.yaml`)

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
        # Trigger SPIRE registration
        spiffe.io/spire-managed-identity: "true"
      annotations:
        # CRITICAL: Tell Istio/Envoy to use the SPIRE bundle as a Trust Root
        proxy.istio.io/config: |
          caCertificatesPem:
          - "/var/run/secrets/spire-bundle/root-cert.pem"
        # Inject the volumes via sidecar annotations
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

## Applying the Patch

To apply the configuration and ensure the Ingress Gateway picks up the changes:

```bash
kubectl apply -f manifest/ingress-spire-patch.yaml
kubectl rollout restart deployment istio-ingress -n istio-ingress
```

## Relationship to Sidecar Injection

While the Ingress Gateway requires a manual patch (or a custom gateway template), standard workloads use the `spire` template defined in `manifest/istio-spire-values.yaml`. 

### Why both are needed:
1. **Consistency**: Both the Gateway and the Sidecars must point to the same SPIRE socket and trust the same root CA bundle to establish a unified identity mesh.
2. **Bootstrapping**: The Gateway is often deployed via its own Helm chart (`istio/gateway`), which doesn't automatically inherit the custom sidecar templates. The patch bridges this gap.
3. **Trust Validation**: Without the `caCertificatesPem` configuration (provided globally in `meshConfig` or locally in the Gateway patch), Envoy would attempt to validate identities against Istio's default CA (istiod) instead of SPIRE, leading to connection resets.

## SPIRE Bundle Consistency

It is critical that the `spire-bundle` ConfigMap in the `istio-ingress` namespace matches the trust root from the `spire-bundle` ConfigMap in the `spire-server` namespace (originally created by the SPIRE Helm chart).

### Key Points:
*   **Source of Truth**: The `spire-server` namespace contains the authoritative bundle.
*   **Format Difference**: While the Helm-created bundle in `spire-server` is in JSON format (`bundle.spiffe`), the Ingress Gateway requires it in PEM format (`root-cert.pem`).
*   **Manual Synchronization**: Ensure that when the SPIRE trust root is updated, the PEM-formatted ConfigMap in the `istio-ingress` namespace is also updated to reflect these changes.

### Replication & Conversion Steps:

To replicate the trust bundle in the `istio-ingress` namespace (or any other namespace requiring PEM format):

```bash
# 1. Extract the bundle in PEM format from the SPIRE Server
kubectl exec -n spire-server spire-server-0 -- /opt/spire/bin/spire-server bundle show -format pem > root-cert.pem

# 2. Create or Update the spire-bundle ConfigMap in the istio-ingress namespace
kubectl create configmap spire-bundle -n istio-ingress --from-file=root-cert.pem --dry-run=client -o yaml | kubectl apply -f -

# 3. Clean up the local file
rm root-cert.pem
```

**Alternative (using jq):** If you cannot exec into the pod, use this command to convert the existing JSON ConfigMap:

```bash
kubectl get configmap spire-bundle -n spire-server -o jsonpath='{.data.bundle\.spiffe}' | \
  jq -r '.keys[] | select(.use=="x509-svid") | .x5c[0]' | \
  while read -r line; do echo "$line" | base64 -d | openssl x509 -inform der; done > root-cert.pem
```

## Verifying Ingress-to-Backend mTLS Communication

### Why You Must Test This Call
Even if the Ingress Gateway and backend pods appear as `Running` without visible logs crash-looping, testing the connection by making a real request is **essential**. This verification:
1. **Verifies the mTLS Handshake**: Ensures that the Ingress Gateway successfully trusts the backend's SPIRE-issued SVID, and that the backend workload sidecar trusts the Ingress Gateway's SPIRE-issued SVID.
2. **Ensures Routing Alignment**: Confirms that your `Gateway` and `VirtualService` resource configs are properly defined, bound to each other, and targeting the correct destination service port.
3. **Cryptographic Proof of Identity**: Allows you to inspect the `X-Forwarded-Client-Cert` (XFCC) header on the backend request. If the connection is correctly authenticated, the sidecar automatically injects this header containing the client's SPIFFE ID, giving you complete assurance that your Zero-Trust infrastructure is operating securely.

### Step-by-Step Testing Guide

#### Step 1: Apply the Gateway & VirtualService Manifest
Create the routing rules that link incoming external traffic to your SPIRE-enabled service.

```bash
kubectl apply -f manifest/ingress-test.yaml
```

*This manifest maps any request entering the gateway with path `/headers` to the internal `httpbin-simple` service.*

#### Step 2: Call the Endpoint through Ingress
Trigger a request from a test client (like `sleep-spire`) or curl directly against your Ingress External IP:

```bash
# Extract the Ingress IP (in Minikube, make sure 'minikube tunnel' is running)
INGRESS_HOST=$(kubectl -n istio-ingress get service istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Call the /headers endpoint on the backend through the Ingress
kubectl exec -n apps deploy/sleep-spire -c sleep -- curl -s http://$INGRESS_HOST/headers
```

#### Step 3: Verify the Identity Header
Look closely at the JSON output returned from `httpbin-simple`. A fully operational and secure SPIRE setup will output a `X-Forwarded-Client-Cert` (XFCC) header containing the SPIFFE ID of the Ingress Gateway:

```json
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin-simple:8000",
    "User-Agent": "curl/8.1.2",
    "X-Forwarded-Client-Cert": "By=spiffe://example.org/ns/apps/sa/httpbin-simple;Hash=...;Subject=\"\";URI=spiffe://example.org/ns/istio-ingress/sa/istio-ingress"
  }
}
```

> [!IMPORTANT]
> If you see `URI=spiffe://example.org/ns/istio-ingress/sa/istio-ingress` in the XFCC header, your Ingress Gateway has successfully joined the trust domain and completed a SPIRE-backed cryptographic mutual TLS handshake with the backend.

