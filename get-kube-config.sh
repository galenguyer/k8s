#!/usr/bin/env bash
# retrieve kube config files so we can use kubectl remotely

# exit if a command fails
set -o errexit
set -o pipefail
# exit if required variables aren't set
set -o nounset

mkdir -p ~/.kube/

if [ -n "$(dig +short k8s-control-plane-01.k8s.stonewall.lan)" ]; then
    echo 'running within cluster...'
    scp k8s-control-plane-01:/etc/kubernetes/admin.conf ~/.kube/config
else
    echo 'running outside cluster...'
    scp root@k8s.galenguyer.com:/root/.kube/config ~/.kube/config
    sed -i 's/k8s-services.k8s.stonewall.lan/k8s.galenguyer.com/g' ~/.kube/config
fi
