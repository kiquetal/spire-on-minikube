# Integration Guide: Keycloak + SPIFFE

This guide outlines the steps to apply the SPIFFE federated authentication to your Minikube environment using the modified Keycloak configuration.

## Step 1: Update Keycloak Deployment
Apply the changes to your `keycloak-for-spiffee.yaml` to include the required features and truststore paths.

```yaml
# Add to environment variables
- name: KC_FEATURES
  value: "token-exchange,token-exchange-standard:v2,admin-fine-grained-authz:v1,spiffe,client-auth-federated"
- name: KC_TRUSTSTORE_PATHS
  value: "/var/run/secrets/spire-bundle/root-cert.pem"
```

## Step 2: Configure SPIRE OIDC Discovery
Ensure SPIRE is serving the JWKS endpoint over HTTP for testing:
*   Endpoint: `http://spire-server.spire-server.svc:8080/keys`

## Step 3: Keycloak Admin Setup

### 1. Configure the SPIFFE Identity Provider
*   Go to **Identity Providers** -> **Add provider** -> **SPIFFE**.
*   **Alias**: `spiffe` (This is the unique identifier used later by the client).
*   **Bundle Endpoint**: `http://spire-server.spire-server.svc:8080/keys` (The internal SPIRE JWKS endpoint).
*   **Accept Untrusted Certificates**: Enable this if testing with self-signed SPIRE certificates without a common Root CA in the system truststore (though `KC_TRUSTSTORE_PATHS` is preferred).

### 2. Create the Workload Client
This client represents your SPIFFE-enabled workload in Keycloak.

*   **General Settings**:
    *   **Client ID**: `workload-client`.
    *   **Name**: `SPIFFE Workload Client`.
*   **Capability Config**:
    *   **Client Authentication**: **ON**. This makes the client "Confidential" (Private). It is mandatory because we are using a `client_assertion` (JWT) to authenticate the client itself.
    *   **Authorization**: **OFF** (unless you need Fine-Grained Authorization).
    *   **Authentication Flow**:
        *   **Standard Flow**: **OFF** (Workloads typically don't use browser-based redirects).
        *   **Service Accounts Roles**: **ON**. This allows the client to obtain tokens via the `client_credentials` grant.
*   **Credentials Tab**:
    *   **Client Authenticator**: Select **Federated Json Web Token**.
    *   **Identity Provider Alias**: `spiffe` (Must match the Alias created in the previous step).
    *   **Subject**: `spiffe://example.org/ns/apps/sa/sleep-spire`. 
        *   *Note*: This is the "Identity" of the workload. Only a JWT-SVID with this exact SPIFFE ID will be accepted for this client.

#### Why is it "Private" (Confidential)?
In OIDC terms, a **Public** client is one that cannot keep a secret (like a browser app). A **Confidential** client can authenticate itself. By enabling **Client Authentication**, we tell Keycloak that this client must prove its identity. Instead of a static `client_secret`, this client uses its SPIFFE-issued JWT-SVID as a dynamic, short-lived secret (the `client_assertion`). This is significantly more secure than a password or long-lived secret.

## Step 4: Testing the Flow
Execute the following command to fetch a JWT-SVID from a SPIRE-enabled pod and exchange it for a Keycloak token. This example uses the `sleep-spire` pod in the `apps` namespace.

```bash
kubectl exec -n apps deploy/sleep-spire -c sleep -- /bin/sh -c '
  set -e
  
  # 1. Download SPIRE Agent (if not present) to fetch the SVID
  if [ ! -f /tmp/spire-agent ]; then
    curl -sL https://github.com/spiffe/spire/releases/download/v1.10.1/spire-1.10.1-linux-amd64-musl.tar.gz | tar xz -C /tmp
    mv /tmp/spire-1.10.1-linux-amd64-musl/bin/spire-agent /tmp/spire-agent
  fi

  # 2. Fetch JWT SVID from the workload socket
  # The audience must match what Keycloak expects or be configured in the IdP
  SVID=$(/tmp/spire-agent api fetch jwt -audience keycloak \
    -socketPath /run/secrets/workload-spiffe-uds/socket \
    -format json | sed -n "s/.*\"token\": \"\(.*\)\".*/\1/p")

  # 3. Exchange SVID for Keycloak Token
  curl -s -X POST http://keycloak.spire-server.svc:8080/realms/master/protocol/openid-connect/token \
    -d "grant_type=client_credentials" \
    -d "client_id=workload-client" \
    -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    -d "client_assertion=$SVID" | jq .
'
```

> **Important**: The **Subject** defined in the Keycloak Client (Step 3) must exactly match the SPIFFE ID of the pod running the command. For `sleep-spire`, this is typically `spiffe://example.org/ns/apps/sa/sleep-spire`.

## Step 5: Token Exchange (Optional)
If this client needs to act on behalf of a user:
1.  Go to the **Target Client** -> **Permissions**.
2.  Enable Permissions.
3.  Add `workload-client` to the `token-exchange` policy.
