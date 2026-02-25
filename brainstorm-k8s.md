# Kubernetes Brainstorming - cert-manager with Istio and SPIRE

## cert-manager Flow in Kubernetes with Istio and SPIRE

This diagram illustrates the complete lifecycle of certificate management using cert-manager in a Kubernetes cluster, including integration with Istio service mesh and SPIRE for workload identity.

![cert-manager Sequence Diagram](images/cert-manager-sequence-diagram.png)

## Key Concepts

### cert-manager Components

- **Certificate CRD**: Kubernetes custom resource that defines a certificate request
- **Issuer/ClusterIssuer**: Represents a certificate authority (CA) that can sign certificates
- **cert-manager Controller**: Watches Certificate resources and manages their lifecycle

### Integration Points

#### Istio Integration
- cert-manager provisions TLS certificates for Istio ingress gateways
- Certificates are stored as Kubernetes Secrets and mounted to gateway pods
- Enables automatic certificate rotation for external-facing services

#### SPIRE Integration
- SPIRE server can use cert-manager for its own TLS certificates
- Provides a trusted root CA for SPIRE's workload identity system
- Separates concerns: cert-manager handles certificate lifecycle, SPIRE handles workload identity

### Certificate Lifecycle

1. **Initial Setup**: Install cert-manager, configure issuers
2. **Certificate Request**: Create Certificate resource, cert-manager generates CSR
3. **Signing**: Issuer forwards CSR to CA, receives signed certificate
4. **Storage**: Certificate and private key stored in Kubernetes Secret
5. **Auto-Renewal**: cert-manager monitors expiry and renews before expiration
6. **Pod Reload**: Applications reload to use new certificates

## Use Cases

### For Istio
- Secure ingress gateway with valid TLS certificates
- Automatic certificate rotation without downtime
- Support for multiple certificate authorities (Let's Encrypt, Vault, etc.)

### For SPIRE
- Bootstrap SPIRE server with trusted certificates
- Establish root of trust for workload identity
- Integrate with existing PKI infrastructure


---

## cert-manager: Istio vs SPIRE Use Cases

This diagram compares how cert-manager is used differently for Istio and SPIRE, and shows how they can work together.

![cert-manager Comparison Diagram](images/cert-manager-comparison-diagram.png)

## Key Differences

### Istio Use Case: External TLS Certificates

**Purpose**: Secure external traffic entering the cluster

**Certificate Authority**: 
- Let's Encrypt (recommended for public certificates)
- HashiCorp Vault (enterprise PKI)

**Certificate Characteristics**:
- Public-facing certificates
- Must be trusted by browsers/clients
- Shorter validity (typically 90 days with Let's Encrypt)
- Requires DNS-01 or HTTP-01 ACME challenges
- Automatic renewal by cert-manager

**Flow**:
1. cert-manager creates Certificate resource for Istio gateway
2. Issuer requests certificate from Let's Encrypt/Vault
3. Certificate stored in Kubernetes Secret
4. Istio ingress gateway mounts the Secret
5. Gateway serves TLS traffic with valid certificate

### SPIRE Use Case: Internal PKI Root

**Purpose**: Bootstrap SPIRE's trust domain and workload identity system

**Certificate Authority**:
- Self-signed CA (recommended for internal root)
- HashiCorp Vault (enterprise integration)

**Certificate Characteristics**:
- Internal-only certificates
- Root CA for SPIRE trust domain
- Longer validity (years, not days)
- No external validation required
- SPIRE then issues short-lived workload certificates (seconds to hours)

**Flow**:
1. cert-manager creates root CA certificate for SPIRE
2. Certificate stored in Kubernetes Secret
3. SPIRE server mounts the Secret as its trust bundle
4. SPIRE uses this root to issue workload identities
5. Workloads get short-lived SVIDs (SPIFFE Verifiable Identity Documents)

## Combined Architecture: Best of Both Worlds

You can use both approaches together:

### 1. cert-manager provisions SPIRE root
- Use cert-manager to create and manage SPIRE's root CA certificate
- Benefit from cert-manager's automation and renewal capabilities
- Integrate with enterprise PKI (Vault) if needed

### 2. SPIRE issues workload identities
- SPIRE handles service-to-service authentication
- Issues short-lived certificates (automatic rotation)
- Provides cryptographic workload identity (SPIFFE)

### 3. Istio uses cert-manager for ingress
- Public-facing ingress gateways get certificates from Let's Encrypt
- Automatic renewal prevents expiration
- Browser-trusted certificates for external users

### 4. Istio uses SPIRE for mTLS mesh
- Internal service mesh uses SPIRE for mTLS
- Automatic certificate rotation (every few hours)
- Strong workload identity without manual certificate management

## Implementation Example

### For Istio Ingress (External TLS)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-gateway-cert
  namespace: istio-system
spec:
  secretName: istio-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - myapp.example.com
    - "*.myapp.example.com"
```

### For SPIRE Root (Internal PKI)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: spire-server-cert
  namespace: spire
spec:
  secretName: spire-bundle
  duration: 87600h  # 10 years
  isCA: true
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
  commonName: spire-root-ca
  subject:
    organizations:
      - "My Organization"
```

## When to Use Each Approach

### Use cert-manager for Istio when:
- You need publicly trusted certificates
- External clients access your services
- You want automatic Let's Encrypt integration
- You need DNS-based certificate validation

### Use cert-manager for SPIRE when:
- You want to bootstrap SPIRE with a trusted root
- You need integration with enterprise PKI (Vault)
- You want automated root CA rotation
- You're establishing a new trust domain

### Use both together when:
- You have both external and internal traffic
- You want public certificates for ingress AND strong internal identity
- You need different certificate lifecycles for different purposes
- You want defense in depth with multiple security layers

---

## SPIRE CA Certificate Setup Process

This diagram shows the complete process of creating and configuring CA certificates for SPIRE using cert-manager.

![SPIRE CA Setup Process](images/spire-ca-setup-process.png)

---

## Step-by-Step: SPIRE Integration with cert-manager

### Prerequisites

- Kubernetes cluster (minikube, kind, or production cluster)
- kubectl configured
- cert-manager installed

### Step 1: Install cert-manager

```bash
# Install cert-manager using kubectl
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Verify installation
kubectl get pods -n cert-manager
kubectl get crd | grep cert-manager
```

### Step 2: Create SPIRE Namespace

```bash
kubectl create namespace spire
```

### Step 3: Create Self-Signed ClusterIssuer

This issuer will create the root CA certificate for SPIRE.

```yaml
# selfsigned-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
```

```bash
kubectl apply -f selfsigned-issuer.yaml
```

### Step 4: Create Root CA Certificate

This is the trust root for your SPIRE deployment.

```yaml
# spire-root-ca.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: spire-root-ca
  namespace: spire
spec:
  isCA: true
  commonName: spire-root-ca
  secretName: spire-root-ca
  duration: 87600h  # 10 years
  renewBefore: 43800h  # Renew 5 years before expiry
  subject:
    organizations:
      - "SPIRE"
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
  privateKey:
    algorithm: RSA
    size: 4096
```

```bash
kubectl apply -f spire-root-ca.yaml

# Wait for certificate to be ready
kubectl wait --for=condition=Ready certificate/spire-root-ca -n spire --timeout=60s

# Verify the certificate
kubectl get certificate -n spire
kubectl describe certificate spire-root-ca -n spire
```

### Step 5: Create CA Issuer from Root Certificate

Now create an issuer that uses the root CA to sign other certificates.

```yaml
# spire-ca-issuer.yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: spire-ca-issuer
  namespace: spire
spec:
  ca:
    secretName: spire-root-ca
```

```bash
kubectl apply -f spire-ca-issuer.yaml
```

### Step 6: Create SPIRE Server Certificate

This certificate will be used by the SPIRE server for TLS communication.

```yaml
# spire-server-cert.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: spire-server
  namespace: spire
spec:
  secretName: spire-server-tls
  duration: 8760h  # 1 year
  renewBefore: 2920h  # Renew 4 months before expiry
  subject:
    organizations:
      - "SPIRE"
  commonName: spire-server
  isCA: false
  privateKey:
    algorithm: RSA
    size: 2048
  usages:
    - server auth
    - client auth
  dnsNames:
    - spire-server
    - spire-server.spire
    - spire-server.spire.svc
    - spire-server.spire.svc.cluster.local
  issuerRef:
    name: spire-ca-issuer
    kind: Issuer
    group: cert-manager.io
```

```bash
kubectl apply -f spire-server-cert.yaml

# Wait and verify
kubectl wait --for=condition=Ready certificate/spire-server -n spire --timeout=60s
kubectl get certificate -n spire
```

### Step 7: Verify Generated Secrets

```bash
# Check the root CA secret
kubectl get secret spire-root-ca -n spire -o yaml

# Check the server certificate secret
kubectl get secret spire-server-tls -n spire -o yaml

# Decode and inspect the root CA certificate
kubectl get secret spire-root-ca -n spire -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -text

# Decode and inspect the server certificate
kubectl get secret spire-server-tls -n spire -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -text
```

### Step 8: Configure SPIRE Server

Create a ConfigMap for SPIRE server configuration that references the certificates.

```yaml
# spire-server-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-server
  namespace: spire
data:
  server.conf: |
    server {
      bind_address = "0.0.0.0"
      bind_port = "8081"
      trust_domain = "example.org"
      data_dir = "/run/spire/data"
      log_level = "DEBUG"
      
      ca_key_type = "rsa-2048"
      ca_ttl = "24h"
      default_x509_svid_ttl = "1h"
      
      # Use cert-manager provided CA
      ca_subject = {
        country = ["US"],
        organization = ["SPIRE"],
        common_name = "SPIRE Server CA",
      }
    }

    plugins {
      DataStore "sql" {
        plugin_data {
          database_type = "sqlite3"
          connection_string = "/run/spire/data/datastore.sqlite3"
        }
      }

      NodeAttestor "k8s_psat" {
        plugin_data {
          clusters = {
            "example-cluster" = {
              service_account_allow_list = ["spire:spire-agent"]
            }
          }
        }
      }

      KeyManager "disk" {
        plugin_data {
          keys_path = "/run/spire/data/keys.json"
        }
      }

      Notifier "k8sbundle" {
        plugin_data {
          namespace = "spire"
          config_map = "spire-bundle"
        }
      }
    }
```

### Step 9: Deploy SPIRE Server

```yaml
# spire-server-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: spire-server
  namespace: spire
  labels:
    app: spire-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: spire-server
  serviceName: spire-server
  template:
    metadata:
      labels:
        app: spire-server
    spec:
      serviceAccountName: spire-server
      containers:
      - name: spire-server
        image: ghcr.io/spiffe/spire-server:1.8.0
        args:
          - -config
          - /run/spire/config/server.conf
        ports:
        - containerPort: 8081
          name: grpc
        volumeMounts:
        - name: spire-config
          mountPath: /run/spire/config
          readOnly: true
        - name: spire-data
          mountPath: /run/spire/data
        - name: spire-server-tls
          mountPath: /run/spire/certs
          readOnly: true
        - name: spire-root-ca
          mountPath: /run/spire/ca
          readOnly: true
        livenessProbe:
          httpGet:
            path: /live
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 60
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: spire-config
        configMap:
          name: spire-server
      - name: spire-server-tls
        secret:
          secretName: spire-server-tls
      - name: spire-root-ca
        secret:
          secretName: spire-root-ca
  volumeClaimTemplates:
  - metadata:
      name: spire-data
    spec:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: spire-server
  namespace: spire
spec:
  type: ClusterIP
  ports:
    - name: grpc
      port: 8081
      targetPort: 8081
      protocol: TCP
  selector:
    app: spire-server
```

### Step 10: Create RBAC Resources

```yaml
# spire-server-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spire-server
  namespace: spire
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: spire-server-cluster-role
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: spire-server-cluster-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: spire-server-cluster-role
subjects:
- kind: ServiceAccount
  name: spire-server
  namespace: spire
```

```bash
kubectl apply -f spire-server-rbac.yaml
kubectl apply -f spire-server-configmap.yaml
kubectl apply -f spire-server-statefulset.yaml
```

### Step 11: Verify SPIRE Server

```bash
# Check pod status
kubectl get pods -n spire

# Check logs
kubectl logs -n spire spire-server-0

# Verify the server is using cert-manager certificates
kubectl exec -n spire spire-server-0 -- ls -la /run/spire/certs
kubectl exec -n spire spire-server-0 -- ls -la /run/spire/ca

# Test SPIRE server health
kubectl exec -n spire spire-server-0 -- /opt/spire/bin/spire-server healthcheck
```

### Step 12: Deploy SPIRE Agent

```yaml
# spire-agent-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: spire-agent
  namespace: spire
  labels:
    app: spire-agent
spec:
  selector:
    matchLabels:
      app: spire-agent
  template:
    metadata:
      labels:
        app: spire-agent
    spec:
      hostPID: true
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      serviceAccountName: spire-agent
      containers:
      - name: spire-agent
        image: ghcr.io/spiffe/spire-agent:1.8.0
        args:
          - -config
          - /run/spire/config/agent.conf
        volumeMounts:
        - name: spire-config
          mountPath: /run/spire/config
          readOnly: true
        - name: spire-bundle
          mountPath: /run/spire/bundle
          readOnly: true
        - name: spire-agent-socket
          mountPath: /run/spire/sockets
        - name: spire-token
          mountPath: /var/run/secrets/tokens
      volumes:
      - name: spire-config
        configMap:
          name: spire-agent
      - name: spire-bundle
        configMap:
          name: spire-bundle
      - name: spire-agent-socket
        hostPath:
          path: /run/spire/sockets
          type: DirectoryOrCreate
      - name: spire-token
        projected:
          sources:
          - serviceAccountToken:
              path: spire-agent
              expirationSeconds: 7200
              audience: spire-server
```

### Step 13: Test Workload Registration

```bash
# Register a workload
kubectl exec -n spire spire-server-0 -- \
  /opt/spire/bin/spire-server entry create \
  -spiffeID spiffe://example.org/ns/default/sa/default \
  -parentID spiffe://example.org/ns/spire/sa/spire-agent \
  -selector k8s:ns:default \
  -selector k8s:sa:default

# List entries
kubectl exec -n spire spire-server-0 -- \
  /opt/spire/bin/spire-server entry show

# Verify agent can fetch SVIDs
kubectl exec -n spire -it spire-agent-xxxxx -- \
  /opt/spire/bin/spire-agent api fetch -socketPath /run/spire/sockets/agent.sock
```

### Step 14: Monitor Certificate Renewal

```bash
# Watch certificate status
kubectl get certificate -n spire -w

# Check certificate expiry dates
kubectl get certificate -n spire -o custom-columns=\
NAME:.metadata.name,\
READY:.status.conditions[0].status,\
EXPIRY:.status.notAfter

# Set up alerts for certificate expiry
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cert-expiry-alert
  namespace: spire
data:
  alert.yaml: |
    - alert: SPIRECertificateExpiringSoon
      expr: certmanager_certificate_expiration_timestamp_seconds{namespace="spire"} - time() < 2592000
      for: 24h
      annotations:
        summary: "SPIRE certificate expiring in less than 30 days"
EOF
```

## Troubleshooting

### Certificate Not Ready

```bash
# Check certificate status
kubectl describe certificate spire-root-ca -n spire

# Check cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager -f

# Check certificate request
kubectl get certificaterequest -n spire
kubectl describe certificaterequest -n spire <request-name>
```

### SPIRE Server Not Starting

```bash
# Check pod events
kubectl describe pod -n spire spire-server-0

# Check if certificates are mounted
kubectl exec -n spire spire-server-0 -- ls -la /run/spire/certs
kubectl exec -n spire spire-server-0 -- ls -la /run/spire/ca

# Verify certificate validity
kubectl exec -n spire spire-server-0 -- \
  openssl x509 -in /run/spire/certs/tls.crt -noout -text
```

### Agent Cannot Connect to Server

```bash
# Check agent logs
kubectl logs -n spire daemonset/spire-agent

# Verify bundle configmap exists
kubectl get configmap spire-bundle -n spire

# Test connectivity
kubectl exec -n spire spire-agent-xxxxx -- \
  nc -zv spire-server.spire.svc.cluster.local 8081
```

## Key Takeaways

1. **Root CA**: Use long-lived (10 years) self-signed certificate as SPIRE trust root
2. **Server Certificate**: Use shorter-lived (1 year) certificate for SPIRE server TLS
3. **Automatic Renewal**: cert-manager handles renewal automatically at 2/3 of lifetime
4. **Mount Points**: Mount both root CA and server certificate to SPIRE server pods
5. **Trust Bundle**: SPIRE publishes trust bundle to ConfigMap for agents to consume
6. **Monitoring**: Always monitor certificate expiry dates and renewal status


---

## Comparison Table: cert-manager Usage for Istio vs SPIRE

| Aspect | Istio (Ingress Gateway) | SPIRE (Server Root CA) |
|--------|------------------------|------------------------|
| **Primary Purpose** | External TLS termination | Internal PKI root bootstrap |
| **Certificate Type** | Leaf/End-entity certificate | Root CA certificate |
| **Trust Requirement** | Public trust (browser/client) | Internal trust domain |
| **Recommended CA** | Let's Encrypt, Public CA | Self-signed, Vault |
| **Certificate Validity** | 90 days (Let's Encrypt) | 1-10 years |
| **Renewal Frequency** | Every 60 days (auto) | Every 1-5 years (manual consideration) |
| **Renewal Method** | Automatic (cert-manager) | Automatic (cert-manager) |
| **Renewal Trigger** | 2/3 of lifetime (30 days before expiry) | 2/3 of lifetime |
| **DNS/HTTP Challenge** | Required (ACME) | Not required |
| **Secret Name** | `istio-ingressgateway-certs` | `spire-server-ca` |
| **Namespace** | `istio-system` | `spire` |
| **Pod Restart Required** | Yes (or use SDS) | Yes |
| **Downtime Risk** | Low (with proper config) | Low (SPIRE handles gracefully) |
| **Certificate Chain** | Full chain from public CA | Self-contained root |
| **Use in Service Mesh** | Ingress only | All workload identities |
| **Rotation Impact** | External clients only | All SPIRE-issued certificates |
| **Monitoring Priority** | High (public-facing) | Critical (trust root) |

## Renewal Strategies

### Best Practices for Istio Certificate Renewal

#### 1. Automatic Renewal Configuration

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-gateway-cert
  namespace: istio-system
spec:
  secretName: istio-ingressgateway-certs
  duration: 2160h    # 90 days
  renewBefore: 720h  # 30 days before expiry
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - myapp.example.com
  privateKey:
    algorithm: RSA
    size: 2048
    rotationPolicy: Always  # Generate new key on renewal
```

#### 2. Gateway Configuration for Zero-Downtime

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: public-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: istio-ingressgateway-certs  # Matches Certificate secretName
    hosts:
    - myapp.example.com
```

#### 3. Monitoring and Alerts

```yaml
# Prometheus alert example
- alert: IstioGatewayCertExpiringSoon
  expr: certmanager_certificate_expiration_timestamp_seconds{name="istio-gateway-cert"} - time() < 604800
  for: 1h
  annotations:
    summary: "Istio gateway certificate expiring in less than 7 days"
```

### Best Practices for SPIRE Certificate Renewal

#### 1. Long-Lived Root CA Configuration

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: spire-root-ca
  namespace: spire
spec:
  secretName: spire-server-ca
  duration: 87600h      # 10 years
  renewBefore: 43800h   # 5 years before expiry (50%)
  isCA: true
  commonName: spire-root-ca
  subject:
    organizations:
      - "My Organization"
  usages:
    - digital signature
    - key encipherment
    - cert sign
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
  privateKey:
    algorithm: RSA
    size: 4096
    rotationPolicy: Always
```

#### 2. SPIRE Server Configuration

```yaml
# spire-server configmap
server {
  trust_domain = "example.org"
  
  ca_subject = {
    country = ["US"],
    organization = ["My Organization"],
    common_name = "SPIRE Server",
  }
  
  # Use cert-manager provided CA
  ca_key_type = "rsa-4096"
  
  # Intermediate CA configuration
  default_x509_svid_ttl = "1h"
  ca_ttl = "24h"
}
```

#### 3. Graceful Root Rotation Strategy

**Option A: Automated with Monitoring**
- Let cert-manager handle renewal automatically
- SPIRE server detects new certificate in mounted Secret
- Restart SPIRE server pods (use rolling update)
- Old certificates remain valid until workloads refresh

**Option B: Manual Control for Critical Systems**
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: spire-root-ca
  namespace: spire
  annotations:
    cert-manager.io/issue-temporary-certificate: "false"  # Wait for manual approval
spec:
  # ... same as above
```

#### 4. Root CA Rotation Process

1. **Preparation Phase** (6 months before expiry)
   - Verify cert-manager will renew automatically
   - Test SPIRE server restart procedure
   - Document rollback plan

2. **Renewal Phase** (automatic at renewBefore threshold)
   - cert-manager creates new certificate
   - Updates Secret with new CA cert and key
   - Kubernetes triggers pod restart (if configured)

3. **Propagation Phase** (after restart)
   - SPIRE server loads new root CA
   - Issues new intermediate CA
   - Workloads gradually get new SVIDs
   - Old SVIDs remain valid until expiry (1 hour default)

4. **Verification Phase**
   - Check all workloads have new certificates
   - Verify mTLS connections working
   - Monitor for authentication failures

## Renewal Comparison

| Feature | Istio Renewal | SPIRE Renewal |
|---------|--------------|---------------|
| **Frequency** | Monthly (every 60 days) | Rare (every 5+ years) |
| **Automation Level** | Fully automatic | Automatic with monitoring |
| **Risk Level** | Low | Medium (trust root change) |
| **Testing Required** | Minimal | Extensive |
| **Rollback Complexity** | Easy | Complex |
| **Client Impact** | None (transparent) | None (if done correctly) |
| **Preparation Time** | None | 6+ months |
| **Best Practice** | Let it auto-renew | Monitor and plan ahead |

## Monitoring Commands

### Check Certificate Status

```bash
# Check Istio certificate
kubectl get certificate -n istio-system istio-gateway-cert -o yaml

# Check SPIRE certificate
kubectl get certificate -n spire spire-root-ca -o yaml

# Check certificate expiry
kubectl get certificate -A -o custom-columns=\
NAME:.metadata.name,\
NAMESPACE:.metadata.namespace,\
READY:.status.conditions[0].status,\
EXPIRY:.status.notAfter
```

### Verify Certificate in Secret

```bash
# Istio certificate
kubectl get secret -n istio-system istio-ingressgateway-certs -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -text

# SPIRE certificate
kubectl get secret -n spire spire-server-ca -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -text
```

### Force Manual Renewal

```bash
# Force renewal (if needed)
kubectl annotate certificate -n istio-system istio-gateway-cert \
  cert-manager.io/issue-temporary-certificate="true" --overwrite

# Delete and recreate (emergency)
kubectl delete secret -n istio-system istio-ingressgateway-certs
# cert-manager will automatically recreate
```

## Key Takeaways

1. **Istio**: Set it and forget it - automatic renewal works well for short-lived public certificates
2. **SPIRE**: Plan ahead - root CA renewal is infrequent but requires careful coordination
3. **Both**: Use cert-manager's automatic renewal, but monitor certificate expiry dates
4. **Best Practice**: Always test renewal procedures in non-production environments first
