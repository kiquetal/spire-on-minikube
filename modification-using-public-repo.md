# Modification Guidelines for SPIFFE Federated Client Authentication

To integrate SPIFFE/SPIRE with Keycloak for client authentication, follow these modifications based on the Keycloak Playground architecture.

## 1. Keycloak Server Setup
Enable the required experimental features during startup:
```bash
./kc.sh start-dev \
  --features=client-auth-federated,spiffe \
  --truststore-paths=/etc/spire/bundle.pem
```
*   `client-auth-federated`: Enables the `federated-jwt` authenticator.
*   `spiffe`: Enables the specialized SPIFFE Identity Provider type.
*   `truststore-paths`: Must point to the SPIRE bundle certificate so Keycloak can trust the JWKS endpoint.

## 2. SPIFFE Identity Provider (IdP) Configuration
In the Keycloak Admin Console, navigate to **Identity Providers** and add a provider of type **SPIFFE**.

*   **Alias**: `spiffe` (This is the identifier used in client configuration).
*   **Trust Domain**: `spiffe://example.org` (Must match your SPIRE trust domain).
*   **Bundle Endpoint**: `http://spire-server.spire-server.svc:8080/keys` (The URL where Keycloak fetches JWKS).
*   **Accept Insecure Connections**: Set to `true` if using HTTP for the bundle endpoint.

## 3. Client Configuration
Create or update a client to use federated authentication:

1.  **Capability Config**: Enable `Service Accounts Enabled`.
2.  **Credentials Tab**:
    *   **Client Authenticator**: Change to `Federated Json Web Token`.
3.  **Federated Settings** (Attributes):
    *   **Identity Provider**: `spiffe` (Matches the IdP alias).
    *   **Subject**: `spiffe://example.org/my-workload` (The literal SPIFFE ID of the workload).

## 4. Token Exchange Permissions
If your workload needs to exchange its SPIFFE-based token for a user token or another client's token, you must configure permissions:

1.  **Enable Fine-Grained Permissions**: On the target client (the one you want to get a token *for*), go to the **Permissions** tab and toggle **Permissions Enabled** to `On`.
2.  **Configure 'token-exchange' Policy**:
    *   Click on the `token-exchange` permission.
    *   Create a **Client Policy** that includes your SPIFFE-authenticated client.
    *   This explicitly allows your SPIFFE workload to perform the `urn:ietf:params:oauth:grant-type:token-exchange` flow.

## 5. Client Assertion (The Token)
The workload sends a `POST` to the token endpoint:

| Parameter | Value |
| :--- | :--- |
| `grant_type` | `client_credentials` |
| `client_id` | `my-keycloak-client` |
| `client_assertion_type` | `urn:ietf:params:oauth:client-assertion-type:jwt-bearer` |
| `client_assertion` | `<JWT-SVID from SPIRE>` |

## 6. One Client for Multiple SPIFFE IDs?
By default, the mapping is 1:1. However, you can map multiple different SPIFFE IDs to the same Keycloak Client using an Identity Provider Mapper.

### Option A: Hardcoded Mapper (Simplest)
1.  Go to **Identity Providers** -> **spiffe** -> **Mappers**.
2.  Add a new mapper of type **Hardcoded Attribute**.
    *   **Name**: `force-internal-client`
    *   **Attribute**: `client_id` (Internal attribute to override)
    *   **Value**: `my-shared-client` (The Client ID in Keycloak)
3.  *Note*: This overrides the client resolution for *all* incoming SPIFFE tokens on this IdP, effectively making this "spiffe" IdP dedicated to that one client.

### Option B: Advanced Pattern Matching
1.  Go to **Identity Providers** -> **spiffe** -> **Mappers**.
2.  Add a new mapper of type **Username Template Importer**.
    *   **Template**: `${CLAIM.sub}`
    *   **Target**: `BROKER_USERNAME`
3.  Then use a **Script Mapper** (requires `scripts` feature) to parse the `sub` claim (the SPIFFE ID) and set the target Keycloak client based on a regex pattern (e.g., all `spiffe://example.org/ns/default/sa/*` map to `workload-client`).

## Summary Checklist
- [x] SPIRE OIDC Discovery enabled.
- [x] Keycloak started with `--features=spiffe,client-auth-federated`.
- [x] `spiffe` IdP created with correct `bundleEndpoint`.
- [x] Keycloak Client set to `clientAuthenticatorType: federated-jwt`.
- [x] Token Exchange permissions granted (if applicable).