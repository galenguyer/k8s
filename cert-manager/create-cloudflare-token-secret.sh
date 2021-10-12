#!/usr/bin/env bash
set -o errexit
set -o pipefail
set -o nounset

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-key-secret
  namespace: cert-manager
type: Opaque
stringData:
  api-key: $CF_API_TOKEN
EOF
