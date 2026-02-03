# 1. Get the SPIRE Server pod name
SPIRE_SERVER=$(kubectl get pods -n spire-server -l app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}')

# 2. Get your Node Name (The "Parent" of the workload)
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

# 3. Create the Registration Entry
kubectl exec -n spire-server $SPIRE_SERVER -c spire-server -- \
  /opt/spire/bin/spire-server entry create \
  -spiffeID spiffe://example.org/ns/apps/sa/httpbin \
  -parentID spiffe://example.org/spire/agent/k8s_psat/demo-cluster/$NODE_NAME \
  -selector k8s:ns:apps \
  -selector k8s:sa:httpbin
