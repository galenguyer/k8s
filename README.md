# k8s
this is going to hurt a lot less than okd. let's do it

this isn't a ha setup. there's two single points of failure in this setup. if pfsense goes down, routing and nat will go down. if haproxy goes down, you won't be able to reach anything inside the cluster. why? we only have so many ip addresses. i don't want to eat all our 49net ips.

## vnets
you'll need two vnets for this. pfsense will sit between them, one talking to the internet and one for interal routing.

## pfsense
pfsense is needed for routing within the vms and nat.

### installation
download the latest amd64 dvd iso from [the website](https://www.pfsense.org/download/).

make sure to set the guest os type to other (pfsense is bsd-based). 1 cores and 2gb of ram is fine.

make sure to give it two network interfaces - one on your public network and one on the internal vnet.

run through the installation with the default values, they'll work fine.


### configuration, part the first
once the installation and reboot is complete, hit `8` to hop into a shell. run `pfctl -d` to disable the firewall temporarily. connect to https://[server ip] and complete the setup wizard. the default login credentials are `admin:pfsense`. 

set the hostname to pfsense and the domain to whatever you want, really. i'm going to use `k8s.stonewall.lan` in this example.

i'm setting the lan ip to 192.168.8.1. feel free to change this, just make sure to keep it consistent.

once you reload, you'll have to run `pfctl -d` to disable the firewall again. you'll have to run this multiple times every time you reload the firewall throughout the next steps.

under firewall>rules, create an allow rule for whatever port you want to change the pfsense admin panel port to run on. i use port 9443 because i don't think i'll ever use that in something else. make sure to apply your changes.

under system>advanced, change the web admin port to whatever port you opened. restart stuff and connect to the web interface on the new port for the next steps.

under services>dns resolver, check "dhcp registration" and "static dhcp" so the machines we set up will be able to resolve each other.

## k8s-services
### installation
create a container with a debian 11 base image. i'm giving it 2 cores, 2 GB of RAM, and 32gb of hard disk space. 

go back to pfsense and under firewall>nat, set up some port forwarding rules for ports like 22, 80, 443, and 6443 to 192.168.8.2. this way you can reach your services machine.

if you didn't add an ssh key, you'll have to edit /etc/ssh/sshd_config and change PermitRootLogin to `yes`

generate an ssh key for use within the cluster with ssh-keygen. you'll use this later

### haproxy

run `apt install haproxy -y` and copy `haproxy.cfg` to `/etc/haproxy/haproxy.cfg`. run `sudo systemctl restart haproxy` to load the new configuration

## k8s-template
we're gonna now create a virtual machine template so we don't need to redo every install step for every machine.

create a virtual machine with 4 cores, 4gb of ram, and 32gb of hard drive space. use the latest debian iso to install debian. use standard options except anything specified below:

* ensure it's on your k8s vnet
* use manual partitioning so you can create a layout without swap
* deselect the desktop environments and select ssh server for additional software

as root, do the following:

* `echo cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory > /boot/cmdline.txt`
* ensure swap is disabled in fstab
* update all packages and install the following packages: `rsync open-iscsi nfs-common gnupg2 curl apt-transport-https ca-certificates`
* enable iscsid: `systemctl enable --now iscsid`
* enable some kernel modules:
    * `echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf`
    * `echo "overlay" > /etc/modules-load.d/overlay.conf`
    * `modprobe br_netfilter`
    * `modprobe overlay`
* add `net.bridge.bridge-nf-call-iptables=1` and `net.ipv4.ip_forward=1` to `/etc/sysctl.conf`
    * load settings with `sysctl -p`
* reboot
* add some gpg signing keys
    * `curl -sSL https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_11/Release.key | apt-key add -`
    * `curl -sSL https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/1.22/Debian_11/Release.key | apt-key add -`
    * `curl -sSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -`
* add the libcontainers and cri-o repos
    * `echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_11/ /" > /etc/apt/sources.list.d/libcontainers.list`
    * `echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/1.22/Debian_11/ /" > /etc/apt/sources.list.d/crio.list`
    * `echo "deb https://apt.kubernetes.io/ kubernetes-xenial main"  > /etc/apt/sources.list.d/kubernetes.list`
* install [cri-o](https://cri-o.io/): `apt update -y && apt install -y cri-o cri-o-runc`
* enable cri-o with `systemctl enable --now crio`
* install kubernetes 1.22.2 (latest as of this guide): `apt install "kubelet=1.22.2-00" "kubeadm=1.22.2-00" "kubectl=1.22.2-00"`
* hold the installed kubernetes versions: `apt-mark hold kubelet && apt-mark hold kubeadm && apt-mark hold kubectl`

this concludes setup of the template. shut the vm down and mark it as a template to create your new masters and workers from.

## kubernetes, for real

give all your masters and workers static ips with pfsense

set all the hostnames to the correct values with `hostnamectl set-hostname` and editing `/etc/hosts` with `sed -i "s/k8s-template/$HOSTNAME/g" /etc/hosts`

### initial master
ssh into k8s-master-01 and run the following command:
```
kubeadm init --apiserver-advertise-address=0.0.0.0 --apiserver-cert-extra-sans="$(curl -sSL ifconfig.me),k8s.galenguyer.com" --kubernetes-version=1.22.2 --pod-network-cidr=10.244.0.0/16 --control-plane-endpoint=k8s-services.k8s.stonewall.lan:6443 --upload-certs
```
make note of the `kubeadm join` commands init provides. we'll be using those later

run the following commands to get kubectl working easily on k8s-master-01
```
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
```

install cluster networking. i'm using calico because flannel seems broken for some reason, idk
```
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

### other masters
kubeadm gave us two join commands. use the provided command to join the other two control plane nodes.

#### making masters scheduleable
to allow pods to run on master nodes, run `kubectl taint nodes --all node-role.kubernetes.io/master-`

### workers
run the other join command to add our workers to the cluster.

you can now run `kubectl get nodes` to see all the available nodes or `kubectl get pods -o wide --all-namespaces` to see all running pods

## kubectl on k8s-services
you'll probably want kubectl on your k8s-services vm. run the following commands to install it:
```
curl -sSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main"  > /etc/apt/sources.list.d/kubernetes.list
apt update -y && apt install "kubectl=1.22.2-00" -y
apt-mark hold kubectl
```

## [longhorn](https://github.com/longhorn/longhorn/)
longhorn is a really cute distributed storage driver. 

### installation
```
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.2.1/deploy/longhorn.yaml
```

it'll take a hot sec to run and eventually you'll have a lot of running pods with `longhorn-driver-deployer` stuck in Init:0/1 and `longhorn-ui` in a CrashLoopBackoff. once you're in that state, reboot all the kubernetes nodes and it should settle down.

### web dashboard

run `kubectl proxy` and navigate to [http://localhost:8001/api/v1/namespaces/longhorn-system/services/http:longhorn-frontend:80/proxy/#/dashboard](http://localhost:8001/api/v1/namespaces/longhorn-system/services/http:longhorn-frontend:80/proxy/#/dashboard)

## [ingress-nginx](https://github.com/kubernetes/ingress-nginx)
i'm going to be using the official nginx ingress controller. i've also had good results with the haproxy ingress controller, but i wanted to try something new.

### installation
use the customized version of the [baremetal deployment](https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.0.2/deploy/static/provider/baremetal/deploy.yaml). the change binds the nodeport to a constant value so our haproxy installation on k8s-services knows where to proxy to.

```
kubectl apply -f nginx-ingress.yaml
```

## [cert-manager](https://cert-manager.io/)
cert-manager is useful for getting certificates from letsencrypt

### installation
from [https://cert-manager.io/docs/installation/kubectl/](https://cert-manager.io/docs/installation/kubectl/):

```
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.5.3/cert-manager.yaml
```

### personal ca
i generated a root ca certificate with [hancock](https://github.com/galenguyer/hancock). the key is stored in cert-manager/ca-key-pair.yaml and encrypted with git-crypt. to install the cert as a secret and set up a cluster issuer, run the following commands
```
kubectl apply -f cert-manager/ca-key-pair.yaml
kubectl apply -f cert-manager/ca-cluster-issuer.yaml
```

## [dashboard](https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/)
a web ui for kubernetes
### installation
`kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.3.1/aio/deploy/recommended.yaml`
### connection
run `kubectl proxy` and go to [http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/](http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/)
#### authorization
apply the service account with `kubectl apply -f dashboard-adminuser.yaml`. get the token with `kubectl -n kubernetes-dashboard get secret $(kubectl -n kubernetes-dashboard get sa/admin-user -o jsonpath="{.secrets[0].name}") -o go-template="{{.data.token | base64decode}}"; echo`

## scripts
* `get-kube-config.sh` will detect if you're running it inside the cluster or not and fetch the kubeconfig file from the correct location. you **must** run it from within the cluster as root first or the file will not be where it expects when running outside the cluster

## proxmox
#### create vms from template
```
qm clone --full=1 --name k8s-master-01 100 802
qm clone --full=1 --name k8s-master-02 100 803
qm clone --full=1 --name k8s-master-03 100 804
qm clone --full=1 --name k8s-worker-01 100 805
qm clone --full=1 --name k8s-worker-02 100 806
```
#### start vms
```
for i in {802..806}; do qm start $i; done
```

### update hostnames
```
ssh k8s-master-01 hostnamectl set-hostname k8s-master-01
ssh k8s-master-02 hostnamectl set-hostname k8s-master-02
ssh k8s-master-03 hostnamectl set-hostname k8s-master-03
ssh k8s-worker-01 hostnamectl set-hostname k8s-worker-01
ssh k8s-worker-02 hostnamectl set-hostname k8s-worker-02
ssh k8s-master-01 sed -i "s/k8s-template/k8s-master-01/g" /etc/hosts
ssh k8s-master-02 sed -i "s/k8s-template/k8s-master-02/g" /etc/hosts
ssh k8s-master-03 sed -i "s/k8s-template/k8s-master-03/g" /etc/hosts
ssh k8s-worker-01 sed -i "s/k8s-template/k8s-worker-01/g" /etc/hosts
ssh k8s-worker-02 sed -i "s/k8s-template/k8s-worker-02/g" /etc/hosts
```