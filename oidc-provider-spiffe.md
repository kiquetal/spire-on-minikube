# SPIRE OIDC Discovery Provider Access

The SPIRE OIDC Discovery Provider is configured to serve discovery documents over **HTTPS** and validates the `Host` header against a pre-defined list of allowed domains.

## How to reach the provider via port-forward

Since the service only exposes port 443 (HTTPS), you must use the `https://` protocol and provide a valid `Host` header that matches one of the domains configured in the provider.

1.  **Start port-forwarding:**
    ```bash
    kubectl port-forward -n spire-server svc/spire-spiffe-oidc-discovery-provider 8443:443
    ```

2.  **Access the OIDC configuration:**
    Use `curl` with the `-k` flag (to ignore self-signed certificates) and the `-H` flag to set the expected `Host`.
    ```bash
    curl -k -H "Host: spire-spiffe-oidc-discovery-provider.spire-server.svc.cluster.local" 
      https://localhost:8443/.well-known/openid-configuration
    ```

## Modifying the allowed hosts (domains)

The allowed domains are defined in the `spire-spiffe-oidc-discovery-provider` ConfigMap. To add or change a host (e.g., to allow `localhost` or a custom external domain), you need to update the `domains` array in the `oidc-discovery-provider.conf` section.

### Step 1: Edit the ConfigMap
You can edit it directly using:
```bash
kubectl edit configmap -n spire-server spire-spiffe-oidc-discovery-provider
```

### Step 2: Update the `domains` list
In the `oidc-discovery-provider.conf` key, find the `"domains"` array and add your new host:

```json
{
  "domains": [
    "spire-spiffe-oidc-discovery-provider",
    "spire-spiffe-oidc-discovery-provider.spire-server",
    "spire-spiffe-oidc-discovery-provider.spire-server.svc.cluster.local",
    "oidc-discovery.example.org",
    "localhost"  <-- Add this to allow direct localhost calls
  ],
  ...
}
```

### Step 3: Restart the Pod
The OIDC provider does not automatically reload its configuration file when the ConfigMap changes. You must restart the pod to apply the new domain settings:

```bash
kubectl rollout restart deployment -n spire-server spire-spiffe-oidc-discovery-provider
```

After restarting, you will be able to reach it without the specific `Host` header if you added `localhost`:
```bash
curl -k https://localhost:8443/.well-known/openid-configuration
```

## Enabling HTTP (Insecure) Access

The provider is configured for HTTPS by default. To allow HTTP (e.g., for simplified testing or internal cluster traffic):

### Step 1: Update the ConfigMap
Add `"insecure_addr": ":8080"` to the `oidc-discovery-provider.conf` section.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-spiffe-oidc-discovery-provider
  namespace: spire-server
data:
  oidc-discovery-provider.conf: |
    {
      "domains": [
        "spire-spiffe-oidc-discovery-provider.spire-server.svc.cluster.local",
        "localhost"
      ],
      "insecure_addr": ":8080",
      "workload_api": {
        "socket_path": "/run/spire/sockets/agent.sock",
        "trust_domain": "example.org"
      }
    }
```

### Step 2: Update the Deployment
Add `containerPort: 8080` to the `spiffe-oidc-discovery-provider` container.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spire-spiffe-oidc-discovery-provider
  namespace: spire-server
spec:
  template:
    spec:
      containers:
        - name: spiffe-oidc-discovery-provider
          # ...
          ports:
            - containerPort: 443
              name: https
            - containerPort: 8080
              name: http
```

### Step 3: Update the Service
Add a port mapping for HTTP (e.g., cluster port 80 to targetPort 8080).

```yaml
apiVersion: v1
kind: Service
metadata:
  name: spire-spiffe-oidc-discovery-provider
  namespace: spire-server
spec:
  ports:
    - name: https
      port: 443
      targetPort: 443
    - name: http
      port: 80
      targetPort: 8080
```

### Step 4: Restart the Pod
Apply the changes and restart the deployment:

```bash
kubectl rollout restart deployment -n spire-server spire-spiffe-oidc-discovery-provider
```

