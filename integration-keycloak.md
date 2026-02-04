# Keycloak 25+ Integration with SPIFFE/SPIRE

This guide details the cleanest method to authenticate SPIFFE-identified workloads against Keycloak using the native **Federated Client Authentication** feature available in Keycloak 25+.

## Prerequisites

*   **Keycloak 25+** running with the `token-exchange` and `admin-fine-grained-authz` features enabled (often required for advanced federation, though basic SPIFFE support might be enabled by default in newer builds).
*   **SPIRE** configured with the OIDC Discovery Provider enabled.
*   **Ingress/Network:** Keycloak must be able to reach the SPIRE OIDC Discovery endpoint (e.g., `https://spire-server:8443/.well-known/openid-configuration`).

## 1. Configure SPIRE OIDC Discovery

Ensure SPIRE is serving its JWKS. In your `server.conf`:

```hcl
server {
    # ...
    jwt_issuer = "https://spire-server" # The issuer string in the JWT
    
    # Enable the OIDC discovery endpoint
    experimental {
        feature_flags = ["oidc_discovery_provider"]
    }
}
```

## 2. Configure Keycloak

### A. Add SPIFFE Identity Provider
Instead of registering a simple OIDC provider, Keycloak 25+ has specific support for SPIFFE.

1.  Go to **Identity Providers**.
2.  Select **SPIFFE** (if available) or **OpenID Connect v1.0**.
    *   *Note:* If a native "SPIFFE" option isn't visible, use the standard **OpenID Connect** provider. Keycloak's "Federated Client Authentication" works by linking a client to an external issuer.
3.  **Alias:** `spire-oidc`
4.  **Discovery Endpoint:** `https://spire-oidc-service:8443/.well-known/openid-configuration`
    *   *Important:* Keycloak needs to trust the CA that signed the SPIRE OIDC TLS certificate. You may need to add the SPIRE CA to Keycloak's truststore.
5.  **Client Authentication:** `client_secret_post` (This is how Keycloak talks to SPIRE, not how your app talks to Keycloak. SPIRE's OIDC endpoint is usually public, so this might be irrelevant or dummy values).

### B. Register the Client
This is the "Cleanest" way. You create **ONE** Keycloak Client representing your logical application or service tier.

1.  **Client ID:** `my-workload-client`
2.  **Client Authentication:** `On`
3.  **Authentication Flow:** `Service Accounts Roles` (Client Credentials) enabled.
4.  **Authentication Method:**
    *   Go to the **Credentials** tab.
    *   **Client Authenticator:** Select **Signed Jwt**.
    *   **Signature Algorithm:** `RS256` (matches SPIRE default).

### C. Link Client to SPIFFE ID (The Magic)
How do we tell Keycloak that `spiffe://example.org/ns/default/sa/my-app` is allowed to act as `my-workload-client`?

#### Method 1: JWKS URL (Standard RFC 7523)
If you want a strict 1:1 mapping:
1.  In Client **Credentials**, set **JWKS URL** to your SPIRE OIDC JWKS endpoint.
2.  Keycloak will fetch keys from there to validate the signature.
3.  **Constraint:** The JWT `sub` (Subject) usually must match the Keycloak `client_id`.
    *   *Issue:* SPIFFE IDs look like URLs (`spiffe://...`), while Keycloak Client IDs are often simple strings.
    *   *Solution:* You can name your Keycloak Client `spiffe://example.org/ns/default/sa/my-app`. This works but is ugly.

#### Method 2: Federated Client Authentication (Optimized)
This allows decoupling the SPIFFE ID from the Keycloak Client ID.

1.  Enable **Federated Client Authentication** (if visible as a specific switch or policy in your version).
2.  Alternatively, use a **Script Mapper** or **Client Policy**:
    *   Create a **Client Registration Policy** that trusts tokens issued by your `spire-oidc` provider.
    *   Configure the client to accept **Any** subject signed by that trusted provider, effectively offloading identity proof to the signature.

## 3. Multiple SPIFFE IDs for One Client?

You asked if one Keycloak Client can support different SPIFFE IDs.

**Yes, but it depends on validation strictness.**

### Approach A: The "Subject Match" (Strict)
*   **Mechanism:** Keycloak expects `JWT.sub == Client.clientId`.
*   **Result:** You need one Keycloak Client per SPIFFE ID.
*   **Pros:** Audit logs clearly show which specific SPIFFE ID accessed the system.
*   **Cons:** Management overhead.

### Approach B: The "Signed JWT" with Certificate/JWKS Trust (Flexible)
*   **Mechanism:** You configure the Keycloak Client to trust the **Issuer** (SPIRE) and relax the Subject check.
*   **How:** 
    *   In modern Keycloak, this is often handled by **Client Policies**. 
    *   You define a policy: "If JWT is signed by SPIRE (verified via JWKS), allow it to authenticate as Client X *IF* it contains specific claims."
    *   Currently, without custom extensions, standard Keycloak is strict about `sub` matching `client_id`.

**Recommendation for "Optimization":**
If you have 5 replicas of a service, they all share the **SAME** SPIFFE ID (`spiffe://.../sa/frontend`). This works perfectly with one Keycloak Client.

If you have *different* services (Frontend, Backend, Worker) that all need to access Keycloak to get tokens:
1.  **Do NOT share one client.** Create `frontend-client`, `backend-client`, etc.
2.  Each has its own permissions/scopes.
3.  This is better security practice.

**If you essentially want "Any valid SPIFFE ID can get a token":**
You are looking for **Token Exchange**.
1.  Client: "I am `anonymous` (or a generic public client)".
2.  Action: "Here is my SPIFFE JWT (Subject Token). Please exchange it for a Keycloak Access Token."
3.  Keycloak: Validates SPIFFE JWT against the configured Identity Provider (`spire-oidc`).
4.  Result: Returns a Keycloak Token with the identity mapped from the SPIFFE ID.
5.  **Benefit:** You don't need to register every SPIFFE ID as a Client. You treat them as "Users" authenticated via the SPIFFE Identity Provider.

## 4. How to Request the Token (Client Side)

Run this from your workload:

```bash
# 1. Get SVID from SPIRE Agent (via Workload API)
# This usually happens automatically via sidecar, saved to disk or env var.
# Let's assume we have the JWT in $SPIFFE_JWT

# 2. Call Keycloak
curl -X POST https://keycloak.example.com/realms/myrealm/protocol/openid-connect/token 
  -d "client_id=my-workload-client" 
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" 
  -d "client_assertion=$SPIFFE_JWT" 
  -d "grant_type=client_credentials"
```

*Note:* If using the **Token Exchange** approach (Identity Provider), the `grant_type` would be `urn:ietf:params:oauth:grant-type:token-exchange`, and `subject_token` would be the SPIFFE JWT.
