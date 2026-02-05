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
