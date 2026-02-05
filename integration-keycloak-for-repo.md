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
From a pod in the cluster, use `curl` to simulate the workload authentication:

```bash
# 1. Get JWT-SVID from SPIRE (pseudo-command)
# SVID=$(spire-agent api fetch jwt -audience keycloak ...)

# 2. Exchange for Keycloak Token
curl -X POST http://keycloak:8080/realms/master/protocol/openid-connect/token 
  -d "grant_type=client_credentials" 
  -d "client_id=workload-client" 
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" 
  -d "client_assertion=$SVID"
```

## Step 5: Token Exchange (Optional)
If this client needs to act on behalf of a user:
1.  Go to the **Target Client** -> **Permissions**.
2.  Enable Permissions.
3.  Add `workload-client` to the `token-exchange` policy.
