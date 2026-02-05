# Federated SPIRE with Istio

This document explains how to configure SPIRE Federation between two clusters and how it impacts workload identity and traffic.

## Architectural Overview

In a federated setup, each cluster maintains its own **Trust Domain**. This provides strong isolation. Cluster A issues identities for its workloads, and Cluster B issues identities for its own.

Federation allows these two distinct authorities to "shake hands" and exchange public keys (Root CAs), so they can cryptographically verify each other's workloads without sharing a single private signing key.

### ASCII Diagram

```text
+-----------------------------------+             +-----------------------------------+
|    Cluster A (alpha.com)          |             |    Cluster B (beta.com)           |
|                                   |             |                                   |
|  +---------------------------+    |             |    +---------------------------+  |
|  |      SPIRE Server A       |<---|----(3)----->|    |      SPIRE Server B       |  |
|  +------------+--------------+    |             |    +------------+--------------+  |
|               |                   |             |                 |                 |
|      (1) Get Identity             |             |        (1) Get Identity           |
|      (2) Push Bundles A+B         |             |        (2) Push Bundles B+A       |
|               |                   |             |                 |                 |
|               v                   |             |                 v                 |
|  +------------+--------------+    |             |    +------------+--------------+  |
|  |  Workload A (Envoy A)     |----|----(4)----->|    |  Workload B (Envoy B)     |  |
|  +---------------------------+    |             |    +---------------------------+  |
|                                   |             |                                   |
+-----------------------------------+             +-----------------------------------+

(1) Workloads request identity from their local SPIRE Server.
(2) SPIRE Server pushes the local SVID and BOTH trust bundles (A and B).
(3) Federation API: SPIRE Servers exchange public bundles (Must be configured in BOTH).
(4) mTLS Request: Envoy verifies the foreign certificate using the federated bundle.
```

---

## 1. Do I need the "SPIRE Component"?

**Yes.** To achieve the setup above, you need specific SPIRE components:

1.  **SPIRE Server & Agent:** The core infrastructure to issue identities.
2.  **SPIRE Federation Config (CRDs):**
    You specifically need the `ClusterFederatedTrustDomain` Custom Resource (or equivalent configuration in `server.conf`). This tells SPIRE Server A:
    > *"Go to `https://spire-b.example.com` and fetch their latest Root CA so my workloads can trust them."*

    **Crucially, this must be applied in BOTH parties.** 
    *   Cluster A needs a config pointing to Cluster B.
    *   Cluster B needs a config pointing to Cluster A.
    
    Without this reciprocal configuration, you would only have one-way trust, which would cause mTLS handshakes to fail.

    **Example Configuration:**
    ```yaml
    apiVersion: spire.spiffe.io/v1alpha1
    kind: ClusterFederatedTrustDomain
    metadata:
      name: beta.com
    spec:
      trustDomain: beta.com
      bundleEndpointURL: "https://spire-server.cluster-b:8443"
      bundleEndpointProfile:
        type: "https_spiffe"
        endpointSpiffeId: "spiffe://beta.com/spire/server"
    ```

---

## 2. What happens if two clusters have the same Namespace?

If Cluster A has a namespace `backend` and Cluster B has a namespace `backend`, **they remain completely distinct identities.**

This is the superpower of SPIFFE ID Federation.

*   **Cluster A Identity:** `spiffe://alpha.com/ns/backend/sa/default`
*   **Cluster B Identity:** `spiffe://beta.com/ns/backend/sa/default`

### Why this matters:
1.  **No Naming Collisions:** You don't need to rename your namespaces or service accounts to avoid conflicts. The `trustDomain` (alpha.com vs beta.com) acts as a unique namespace prefix.
2.  **Explicit Access:** A service in Cluster A **cannot** access a service in Cluster B just because they have the same name. You must write an explicit `AuthorizationPolicy`:

    ```yaml
    apiVersion: security.istio.io/v1beta1
    kind: AuthorizationPolicy
    metadata:
      name: allow-cluster-b
      namespace: backend
    spec:
      action: ALLOW
      rules:
      - from:
        - source:
            # Explicitly allowing the FOREIGN identity
            principals: ["spiffe://beta.com/ns/backend/sa/default"]
    ```

### Contrast with Standard Istio Multicluster
In standard Istio Multicluster (shared trust), `ns/backend` in Cluster A is often considered "the same service" as `ns/backend` in Cluster B. Traffic might load balance between them automatically.

In **Federated SPIRE**, they are treated as external, trusted partners. You have strictly separated failure domains.

---

## 3. Cross-Cluster Connectivity (The Networking Bridge)

SPIRE handles **Identity** (Who are you?) and **Trust** (Do I trust you?), but it does not handle **Discovery** (How do I find you?). 

If `svcA` in Cluster A needs to call `svcB` in Cluster B, and they both live in the `apps` namespace, you must bridge the networking gap using Istio's `ServiceEntry`.

### 1. Discovery via ServiceEntry (Cluster A)
Since `svcB` does not exist in Cluster A's local registry, calling `http://svcB.apps.svc.cluster.local` would normally fail. You must define it manually:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: external-svc-b
  namespace: apps
spec:
  hosts:
  - svcB.apps.svc.cluster.local
  location: MESH_EXTERNAL
  ports:
  - number: 80
    name: http
    protocol: HTTP
  resolution: DNS
  endpoints:
  - address: <CLUSTER_B_GATEWAY_IP>
    ports:
      http: 15443 # The port where Cluster B's Envoy Gateway is listening
```

**Why port 15443?**
In an Istio East-West setup, the Gateway runs an Envoy proxy. Port `15443` is typically configured for **SNI Proxying**. It allows the gateway to receive an mTLS connection, look at the SNI header (e.g., `svcB.apps.svc.cluster.local`), and route the encrypted traffic to the correct pod without "terminating" the mTLS. This preserves the SPIRE-issued identity end-to-end.

### 2. Fine-Grained Security (Cluster B)
On the receiving side, Cluster B must explicitly allow this foreign identity. Because the namespace names are identical, you **must** use the full SPIFFE ID in your `AuthorizationPolicy`.

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-svca-from-alpha
  namespace: apps
spec:
  selector:
    matchLabels:
      app: svcB
  action: ALLOW
  rules:
  - from:
    - source:
        # Crucially: We check the foreign TRUST DOMAIN (alpha.com)
        principals: ["spiffe://alpha.com/ns/apps/sa/svcA"]
```

### Summary of the Flow:
1.  **svcA** calls the `ServiceEntry` hostname.
2.  **Envoy A** wraps the request in mTLS using its **alpha.com** identity.
3.  **Envoy A** routes the traffic to **Cluster B's Gateway** on port `15443`.
4.  **Cluster B Gateway** (Envoy) routes the traffic to **svcB**.
5.  **svcB** verifies the **alpha.com** certificate against the federated bundle and allows access.
