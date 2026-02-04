# Keycloak 26+ Integration with SPIFFE/SPIRE

This guide details the **stable and modern** method to authenticate SPIFFE-identified workloads against Keycloak 26+ without relying on preview features. It uses **OAuth 2.0 Token Exchange (RFC 8693)**, which is stable as of Keycloak 26.2.

## Core Strategy: Token Exchange
Instead of treating every SPIFFE ID as a "Client", we treat the SPIRE Trust Domain as an **Identity Provider**. 

**Key Concept:** You use **one** Keycloak Client (a "bridge") to exchange many different SPIFFE identities. 
1. Workloads fetch a unique **SPIFFE JWT** from the local SPIRE agent.
2. Workloads send this JWT as a "Proof of Identity" to Keycloak using a shared `client_id`.
3. Keycloak validates the SPIFFE identity and returns a **Keycloak Access Token** representing that specific workload.

## 1. Prerequisites

*   **Keycloak 26.2+** (Token Exchange is stable).
*   **SPIRE** with OIDC Discovery Provider enabled.
*   **Trust:** Keycloak must trust the CA that signed the SPIRE OIDC TLS certificate (or be configured to skip verification in development).

## 2. Keycloak Configuration (The "Easy" Way)

### A. Add SPIRE as an Identity Provider
This is how you "Trust the Domain" globally.

1.  Go to **Identity Providers** -> **Add provider** -> **OpenID Connect v1.0**.
2.  **Alias:** `spire`
3.  **Display Name:** `SPIRE Trust Domain`
4.  **Discovery Endpoint:** `https://spire-oidc-provider:8443/.well-known/openid-configuration` (or `http://...` in development to skip TLS requirements).
5.  **Trust Domain Validation:** Keycloak will automatically trust tokens where the `iss` (Issuer) matches this discovery endpoint. This effectively trusts your entire SPIFFE domain.
6.  **Client ID / Secret:** Use dummy values (e.g., `spire-idp` / `none`) as we are only using this for token validation, not for the authorization code flow.

### B. Configure the Application Client
Create a single client representing your application tier (e.g., your microservices).

1.  **Client ID:** `my-app-tier`
2.  **Capability Config:** Enable **Client authentication** and **Service accounts roles**.
3.  **Token Exchange Permission:**
    *   Go to the **Permissions** tab for this client.
    *   Enable **Permissions**.
    *   Click on **token-exchange** and create a policy that allows the `my-app-tier` client to exchange tokens from the `spire` identity provider.

## 3. Obtaining the Token (Workload Side)

Your workload uses the `spire-agent` (usually via a sidecar or CSI driver) to get a JWT, then calls Keycloak.

### Step 1: Fetch JWT from SPIRE Agent
From within your pod/container:

```bash
# Fetch a JWT with Keycloak as the audience
# The SPIRE agent socket is usually at /run/spire/sockets/agent.sock
export SPIFFE_JWT=$(spire-agent api fetch jwt -audience "https://keycloak.example.com/realms/myrealm" | awk 'NR==2 {print $1}')
```

### Step 2: Exchange for Keycloak Token
Exchange the **SPIFFE JWT** (which acts as your proof of identity) for a Keycloak token. Note that `subject_token` is your SPIFFE JWT, and the resulting Keycloak token will carry the identity of your specific SPIFFE ID.

```bash
curl -X POST https://keycloak.example.com/realms/myrealm/protocol/openid-connect/token \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "client_id=my-app-tier" \
  -d "client_secret=YOUR_CLIENT_SECRET" \
  -d "subject_token=$SPIFFE_JWT" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
  -d "subject_issuer=spire"
```

The `client_id` provides the **permission** to exchange, while the `$SPIFFE_JWT` provides the **identity**.

## 4. Why this is better

1.  **No Preview Features:** Token Exchange is stable in Keycloak 26.2+. You don't need `--features=preview`.
2.  **Easy Trust:** You configure the SPIRE OIDC endpoint **once** as an Identity Provider. Any workload with a valid SVID from that domain can now "exist" in Keycloak.
3.  **Decoupled Identity:** You don't need to register every single SPIFFE ID as a Keycloak Client. You only manage **one client ID** for your entire application tier, while still getting unique tokens for every service account.
4.  **Standardized:** Uses RFC 8693 (Token Exchange) which is the industry standard for this pattern.

## Troubleshooting

*   **Issuer Mismatch:** Ensure the `jwt_issuer` in SPIRE's `server.conf` matches exactly with the `issuer` in the OIDC Discovery and the Identity Provider config in Keycloak.
*   **SSL/TLS:** If using self-signed certs for SPIRE OIDC, you MUST import the SPIRE CA into the Keycloak/Java truststore.
    *   **Development Tip:** In lab environments, you can avoid truststore updates by using `http` for the SPIRE OIDC provider (if exposed) or by setting the Keycloak environment variable `KC_HTTPS_CLIENT_AUTH=none` and relevant Quarkus properties to disable strict hostname/certificate checks if your environment allows it. However, importing the CA is the recommended stable path.