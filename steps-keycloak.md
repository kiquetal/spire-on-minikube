# Steps to Integrate Keycloak with SPIRE (OIDC Federation)

This guide walks you through setting up Keycloak 26.5+ to accept SPIFFE IDs (via SPIRE) as valid credentials using OAuth 2.0 Token Exchange.

## 1. Deploy Keycloak

Apply the prepared manifest to deploy Keycloak in the `spire-server` namespace.

```bash
kubectl apply -f keycloak-for-spiffee.yaml
```

Wait for it to become ready:

```bash
kubectl rollout status deployment/keycloak -n spire-server
```

## 2. Access the Keycloak Admin Console

If you are on Minikube, you can expose the service URL:

```bash
minikube service keycloak -n spire-server
```

Or use port-forwarding:

```bash
kubectl port-forward svc/keycloak -n spire-server 8080:8080
```
Then navigate to [http://localhost:8080](http://localhost:8080).

*   **Username:** `admin`
*   **Password:** `admin`

## 3. Configure SPIRE as an Identity Provider

This step tells Keycloak to trust tokens issued by your SPIRE infrastructure.

1.  **Log in** to the Administration Console.
2.  (Optional) Create a new Realm (e.g., `spire-demo`) or use `master`.
3.  Navigate to **Identity Providers** in the left menu.
4.  Click **Add provider**. Select **SPIFFE** (this is available because we enabled `preview` features in the deployment).
    *   *Note:* The dedicated SPIFFE provider is optimized for SPIRE integration.
5.  Fill in the form:
    *   **Alias:** `spire`
    *   **Display Name:** `SPIRE Trust Domain`
    *   **Discovery Endpoint:** 
        *   `https://spire-spiffe-oidc-discovery-provider.spire-server.svc.cluster.local:443/.well-known/openid-configuration`
        *   *Note:* Since your provider is exposed on port 443, you **must** use the `https` protocol.
6.  **Important - Trusting the Certificate:**
    *   **SSL Trust:** Keycloak will attempt to verify the TLS connection to port 443. We have mounted the `spire-bundle` ConfigMap into Keycloak and set `KC_TRUSTSTORE_PATHS` to ensure Keycloak trusts the SPIRE CA.
    *   **Hostname Verification:** If you encounter errors related to certificate names, ensure the Discovery Endpoint URL matches one of the domains in the SPIRE OIDC configuration (see `oidc-provider.md`).
    *   **Dev Shortcut:** If you still face TLS issues on 443, you can try setting the environment variable `KC_SPI_TRUSTSTORE_FILE_HOSTNAME_VERIFICATION_POLICY=ANYWHERE` in the Keycloak deployment (though importing the CA via `KC_TRUSTSTORE_PATHS` is usually sufficient).
7.  Click **Add**.

## 4. Configure Application Client

Create a client that your workloads will use to "login" (exchange their SPIFFE JWT for a Keycloak token).

1.  Navigate to **Clients**.
2.  Click **Create client**.
3.  **Client ID:** `my-workload-client`
4.  **Capability config:**
    *   **Client authentication:** `On` (Service Accounts requires this)
    *   **Service accounts roles:** `On`
5.  Click **Save**.
6.  Go to the **Credentials** tab and copy the **Client Secret**.

## 5. Enable Token Exchange Permission

1.  In the `my-workload-client` settings, go to the **Permissions** tab.
2.  Enable **Permissions** (toggle On).
3.  Click on the link for **token-exchange** permission (usually auto-generated).
4.  In the Policy section, click **Create policy** -> **Client**.
    *   (Actually, we want to allow the *Identity Provider*).
    *   *Correction:* We need to define *who* can exchange.
    *   Let's simplify: Go to **Identity Providers** -> `spire` -> **Permissions**.
    *   Enable Permissions.
    *   Click **token-exchange**.
    *   Add a policy that allows `my-workload-client`.
    *   *Simpler Global Mode:* If you just want to test, you can create a "Positive" policy that effectively allows 'Any Client' or specifically `my-workload-client`.

## 6. Verification (The "Show Me" Step)

From a pod inside the cluster (e.g., `sleep-spire`):

1.  **Get SPIFFE JWT:**
    ```bash
    # Audience must match the Keycloak Realm URL usually, or be generic if Keycloak is lenient.
    # For OIDC Federation, the audience in the SPIFFE JWT is checked against the IDP config.
    token=$(spire-agent api fetch jwt -audience "https://spire-spiffe-oidc-discovery-provider..." -socketPath /run/spire/sockets/agent.sock | awk 'NR==2 {print $1}')
    ```

2.  **Exchange Token:**
    ```bash
    curl -X POST http://keycloak.spire-server.svc.cluster.local:8080/realms/master/protocol/openid-connect/token 
      -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" 
      -d "client_id=my-workload-client" 
      -d "client_secret=<YOUR_SECRET>" 
      -d "subject_token=$token" 
      -d "subject_token_type=urn:ietf:params:oauth:token-type:jwt" 
      -d "subject_issuer=spire"
    ```
