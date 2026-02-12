# Integration Guide: Keycloak + SPIFFE

This guide outlines the steps to apply the SPIFFE federated authentication to your Minikube environment using the modified Keycloak configuration.

## Step 0: Prepare SPIRE Trust Bundle ConfigMap (PEM format)
Keycloak and Istio require the SPIRE trust bundle in **PEM format**. 

By default, the `spire-bundle` ConfigMap created by the SPIRE Helm chart contains the bundle in **JSON format** (usually under the key `bundle.spiffe` or `spiffe.bundle`), which is not compatible with Keycloak's `KC_TRUSTSTORE_PATHS`.

To create the required `spire-bundle-pem` ConfigMap:

```bash
# 1. Extract the bundle in PEM format from the SPIRE Server
kubectl exec -n spire-server spire-server-0 -- /opt/spire/bin/spire-server bundle show -format pem > root-cert.pem

# 2. Create the spire-bundle-pem ConfigMap in the spire-server namespace
kubectl create configmap spire-bundle-pem -n spire-server --from-file=root-cert.pem --dry-run=client -o yaml | kubectl apply -f -

# 3. (Optional) If you are using the 'apps' namespace for workloads, 
# you might need it there too if not using the sidecar injector for everything
kubectl create configmap spire-bundle-pem -n apps --from-file=root-cert.pem --dry-run=client -o yaml | kubectl apply -f -
```

**Note**: If you want to automate this, you can configure the SPIRE Server to publish the bundle as PEM directly, but manual creation is the quickest fix for this error.

### Advanced: Converting from JSON ConfigMap
If you cannot run `kubectl exec` on the SPIRE server, you can convert the existing JSON-formatted `spire-bundle` ConfigMap using `jq` and `openssl`:

```bash
kubectl get configmap spire-bundle -n spire-server -o jsonpath='{.data.bundle\.spiffe}' | \
  jq -r '.keys[] | select(.use=="x509-svid") | .x5c[0]' | \
  while read -r line; do echo "$line" | base64 -d | openssl x509 -inform der; done > root-cert.pem
```

## Step 1: Update Keycloak Deployment
Apply the changes to your `manifest/keycloak-for-spiffee.yaml` to include the required features and truststore paths.

```yaml
# Add to environment variables
- name: KC_FEATURES
  value: "token-exchange,token-exchange-standard:v2,admin-fine-grained-authz:v1,spiffe,client-auth-federated"
- name: KC_TRUSTSTORE_PATHS
  value: "/var/run/secrets/spire-bundle/root-cert.pem"
```

## Step 2: Configure SPIRE OIDC Discovery
Ensure SPIRE is serving the JWKS endpoint over HTTP for testing:
*   Endpoint: `http://spire-server.spire-server.svc:8080/keys` (Served by the OIDC Discovery Provider service).

## Step 3: Keycloak Admin Setup

### 1. Configure the SPIFFE Identity Provider
*   Go to **Identity Providers** -> **Add provider** -> **SPIFFE**.
*   **Alias**: `spiffe` (This is the unique identifier used later by the client).
*   **Bundle Endpoint**: `http://spire-spiffe-oidc-discovery-provider.spire-server.svc.cluster.local/keys` (The internal SPIRE JWKS endpoint).
*   **Accept Untrusted Certificates**: Enable this if testing with self-signed SPIRE certificates without a common Root CA in the system truststore (though `KC_TRUSTSTORE_PATHS` is preferred).

### 2. Create the Workload Client
You can name your client anything (e.g., `workload-client`), but you must map it to the specific SPIFFE ID of your workload.

*   **General Settings**:
    *   **Client ID**: `workload-client` (Internal Keycloak ID).
    *   **Name**: `SPIFFE Workload Client`.
*   **Capability Config**:
    *   **Client Authentication**: **ON**. This makes the client "Confidential".
    *   **Authorization**: **OFF**.
    *   **Authentication Flow**:
        *   **Standard Flow**: **OFF**.
        *   **Service Accounts Roles**: **ON**.
*   **Credentials Tab**:
    *   **Client Authenticator**: Select **Federated Json Web Token**.
    *   **Identity Provider Alias**: `spiffe` (Must match the Alias created in Step 3.1).
    *   **Subject**: `spiffe://example.org/ns/apps/sa/debug-spire` (The SPIFFE ID of the workload you want to authenticate).

## Step 4: Deploy Debug Pod
Deploy the `debug-spire` pod which includes the SPIRE agent binary and necessary tools (`curl`, `jq`).

```bash
kubectl apply -f manifest/debug-spire.yaml
```

## Step 5: Testing the Flow
When using the strict `jwt-spiffe` assertion type, the **Client ID parameter in your request** must match the **SPIFFE ID** (the Subject of the JWT), even if the Keycloak Client ID is different.

**Important**: 
1. The `audience` used when fetching the SPIFFE JWT **must** be the Keycloak Realm URL.
2. The `client_id` in the curl command **must** be the SPIFFE ID.

```bash
# 1. Fetch JWT SVID with correct audience (Keycloak Realm URL)
TOKEN=$(kubectl exec -n apps debug-spire -c tools -- spire-agent api fetch jwt \
  -audience http://keycloak.spire-server.svc:8080/realms/spire-demo \
  -socketPath /run/secrets/workload-spiffe-uds/socket \
  -format json | jq -r '.svids[0].token')

# 2. Exchange SVID for Keycloak Token
kubectl exec -n apps debug-spire -c tools -- curl -X POST -s http://keycloak.spire-server.svc:8080/realms/spire-demo/protocol/openid-connect/token \
    -d "grant_type=client_credentials" \
    -d "client_id=spiffe://example.org/ns/apps/sa/debug-spire" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe" \
    -d "client_assertion=$TOKEN" | jq .
```

## How to validate with a different SPIFFE ID?

If you want to authenticate a different workload (e.g., a pod running as `spiffe://example.org/ns/apps/sa/another-app`), you need to register a separate Keycloak Client for it.

1.  **Create a New Client**:
    *   **Client ID**: `another-workload` (Or any name you prefer).
    *   **Credentials -> Subject**: `spiffe://example.org/ns/apps/sa/another-app`
    *   **Credentials -> Identity Provider Alias**: `spiffe`
2.  **Authenticate**:
    *   Fetch the JWT from the new pod.
    *   Send the request using the **SPIFFE ID** as the `client_id` parameter:
        ```bash
        -d "client_id=spiffe://example.org/ns/apps/sa/another-app"
        ```

Keycloak uses the `jwt-spiffe` assertion type to find the client configuration that matches the provided SPIFFE ID (Subject).
