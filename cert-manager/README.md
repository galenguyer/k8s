# cert-manager

## kubed
certificates are normally scoped to only the namespace they were created in. kubed lets us sync those certificates across all namespaces

installation instructions can be found on [https://appscode.com/](https://appscode.com/products/kubed/v0.12.0/setup/install/). you'll need [helm](https://helm.sh/).
```bash
helm install kubed appscode/kubed -n kube-system --set enableAnalytics=false --set config.clusterName=stonewall
```
add the following annotation to the secret to sync it to other namespaces:
```yaml
  annotations:
    kubed.appscode.com/sync: "cert-manager-tls=namespace"
```
add the following label to the namespace you want it synced to:
```yaml
  labels:
    cert-manager-tls: namespace
```
