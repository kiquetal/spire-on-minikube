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
1.  **Identity Provider**:
    *   Add Provider -> **SPIFFE**.
    *   Alias: `spiffe`.
    *   Bundle Endpoint: `http://spire-server.spire-server.svc:8080/keys`.
2.  **Client**:
    *   Create client `workload-client`.
    *   Authentication: `Federated Json Web Token`.
    *   IdP Alias: `spiffe`.
    *   Subject: `spiffe://example.org/ns/spire-server/sa/default`.

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
