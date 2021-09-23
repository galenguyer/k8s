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

go back to pfsense and under firewall>nat, set up some port forwarding rules for ports like 22, 80, and 443 to 192.168.8.2. this way you can reach your services machine.

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
* reboot
* add some gpg signing keys
    * `curl -sSL https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_11/Release.key | apt-key add -`
    * `curl -sSL https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/1.21/Debian_11/Release.key | apt-key add -`
    * `curl -sSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -`
* add the libcontainers and cri-o repos
    * *NOTE:* cri-o 1.22 is out but the debian 11 builds are broken. i'm gonna file an issue if it's not resolved tomorrow
    * `echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_11/ /" > /etc/apt/sources.list.d/libcontainers.list`
    * `echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/1.21/Debian_11/ /" > /etc/apt/sources.list.d/crio.list`
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
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

install cluster networking. i'm using flannel because that's what i found. use what you want, it doesn't really matter.
```
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
```

### other masters
kubeadm gave us two join commands. use the provided command to join the other two control plane nodes.

### workers
run the other join command to add our workers to the cluster.

you can now run `kubectl get nodes` to see all the available nodes or `kubectl get pods -o wide --all-namespaces` to see all running pods

## troubleshooting

### coredns
if the coredns pods are stuck creating, run the following commands:
```
ip link set cni0 down && ip link set flannel.1 down
ip link delete cni0 && ip link delete flannel.1
systemctl restart crio && systemctl restart kubelet 
```
