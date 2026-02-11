# Modifying the Cluster Name

To change the cluster name (e.g., from `demo-cluster` to `my-cluster`), you need to update several configuration files to ensure consistency across SPIRE and Istio.

## 1. SPIRE Server Configuration (`manifest/spire-values.yaml`)

You need to update the cluster name in two places within the SPIRE configuration: the Node Attestor and the Controller Manager.

### Node Attestor (PSAT)
If you are using the `k8s_psat` node attestor, you must update the cluster list:

```yaml
spire-server:
  configuration:
    plugins:
      node_attestor:
        k8s_psat:
          enabled: true
          config:
            clusters:
              "my-cluster": # Change this from "demo-cluster"
                service_account_allow_list: ["spire:spire-agent"]
```

### Controller Manager
Update the `clusterName` used by the SPIRE Controller Manager for generating SPIFFE IDs:

```yaml
spire-server:
  controllerManager:
    enabled: true
    clusterName: "my-cluster" # Add or update this line
```

## 2. Istio Configuration (`manifest/istio-spire-values.yaml`)

Istio needs to know the cluster name for telemetry and multi-cluster identification.

Add or update the `global.multiCluster` section:

```yaml
global:
  multiCluster:
    clusterName: "my-cluster"
```

## 3. Workload Registration Scripts (`register-httpbin.sh`)

If you have manual registration scripts, ensure the `-parentID` matches the new cluster name:

```bash
# Before:
# -parentID spiffe://example.org/spire/agent/k8s_psat/demo-cluster/$NODE_NAME \

# After:
-parentID spiffe://example.org/spire/agent/k8s_psat/my-cluster/$NODE_NAME \
```

## 4. Apply the changes

After updating the files, re-apply the Helm charts. 

> **Important**: Since Istio was installed using Helm (as seen in `Readme.md`), you should continue using `helm upgrade` to apply changes. Avoid using `istioctl install` on a Helm-managed installation, as it can cause configuration drift and conflicts between the two management tools.

```bash
# Update SPIRE
helm upgrade spire spiffe/spire -n spire-server -f manifest/spire-values.yaml

# Update Istio
helm upgrade istiod istio/istiod -n istio-system -f manifest/istio-spire-values.yaml
```

## 5. Verification

Verify that the SPIRE server is using the new cluster name by checking the logs:
```bash
kubectl logs -n spire-server statefulset/spire-server -c spire-server | grep "my-cluster"
```

Also, verify the Istio proxy configuration for any workload:
```bash
istioctl proxy-config bootstrap <pod-name> -n <namespace> | grep cluster_name
```

## 6. Verifying mTLS and Certificates

To verify that mTLS is correctly enabled in a namespace and that workloads are using the expected certificates, you can use these commands.

### Verify Namespace mTLS Policy
First, check if a `PeerAuthentication` policy is defined for the namespace. This is what enforces mTLS at the namespace level.

```bash
# Check for PeerAuthentication resources in the namespace
kubectl get peerauthentication -n <namespace>

# Check for configuration issues in the namespace
istioctl analyze -n <namespace>
```

### Check mTLS Status for a Workload
The `describe` command is the most direct way to see if a workload is actually using mTLS and which policy is being applied.

```bash
# Verify mTLS for a specific pod
istioctl x describe pod <pod-name> -n <namespace>
```

**Example Output:**
```text
Pod: httpbin-74fb669cc6-9v98j
...
Authentication Policies:
   Applied mTLS Policy: STRICT  <-- STRICT means mTLS is required and plain HTTP is rejected
...
```

### Verify Certificates (Optional: SPIRE Integration)
To ensure the certificates are being correctly issued (by SPIRE or Istiod), inspect the proxy's secrets:

```bash
# List secrets for a pod
istioctl proxy-config secret <pod-name> -n <namespace>
```

To verify the identity (SPIFFE ID) inside the certificate:

```bash
istioctl proxy-config secret <pod-name> -n <namespace> -o json | jq -r '.dynamicActiveSecrets[] | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes' | base64 -d | openssl x509 -text -noout | grep "Subject Alternative Name" -A 1
```
