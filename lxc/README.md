# k8s on lxc because uhh
i blame mary

## setup
vnets, pfsense, and k8s-services are all the same

## host setup
because the kernel is shared we have to set some stuff up on your host instead of in a vm.
* run this:
```
mkdir -p /etc/systemd/system/user@.service.d
cat <<EOF | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
[Service]
Delegate=cpu cpuset io memory pids
EOF
```
* enable some kernel modules:
    * `echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf`
    * `echo "overlay" > /etc/modules-load.d/overlay.conf`
    * `modprobe br_netfilter`
    * `modprobe overlay`
* set the following sysctl values. if you don't kubelet will just crash. because the people who wrote kubelet should be shot in the face for not letting me set feature gates that i want.
```
# What K8S tells us:
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
# What it doesn't:
kernel.panic = 10
kernel.panic_on_oops = 1
vm.overcommit_memory = 1
# kube-proxy
net.netfilter.nf_conntrack_max = 786432
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 3600
```
* load settings with `sysctl --system`
* reboot

## k8s-template
create a privileged container with nesting enabled.

use the debian template

i'm doing a 16gb root disk to start, will expand if needed

4 cores, 4gb ram. **make sure you disable swap**

put it on your network, use dhcp so pfsense will give it an ip

add the following to the config file for the container:
```
lxc.mount.entry: /boot boot none bind,ro
lxc.cap.drop: 
```
add nesting=1 to the features section in config

you can now attach from the host with `lxc-attach`

uncomment `en_US.UTF-8` from `/etc/locale.gen` and run `locale-gen`. run `echo LANG=en_US.UTF-8 > /etc/locale.conf`. also run `dpkg-reconfigure tzdata` to set the timezone

do an apt update and install the following packages: `open-iscsi nfs-common gnupg2 curl apt-transport-https ca-certificates`

enable iscsid: `systemctl enable --now iscsid`

add some gpg signing keys
```bash
curl -sSL https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_11/Release.key | apt-key add -
curl -sSL https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/1.22/Debian_11/Release.key | apt-key add -
curl -sSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
```
add the libcontainers and cri-o repos
```bash
echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_11/ /" > /etc/apt/sources.list.d/libcontainers.list
echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/1.22/Debian_11/ /" > /etc/apt/sources.list.d/crio.list
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main"  > /etc/apt/sources.list.d/kubernetes.list
```

install [cri-o](https://cri-o.io/): `apt update -y && apt upgrade -y && apt install -y cri-o cri-o-runc`

enable cri-o with `systemctl enable --now crio`

install kubernetes 1.22.2 (latest as of this guide): `apt install "kubelet=1.22.2-00" "kubeadm=1.22.2-00" "kubectl=1.22.2-00"`

hold the installed kubernetes versions: `apt-mark hold kubelet && apt-mark hold kubeadm && apt-mark hold kubectl`

kubelet will try to read from /dev/kmesg which will fail. run the following to prevent kublet crashes:
```
echo 'L /dev/kmsg - - - - /dev/null' > /etc/tmpfiles.d/kmsg.conf
```
your template is now done. you can clone it to make masters and workers. make sure to give them static ips that match your haproxy config in pfsense.

## k8s-master-01
attach to your first master and drop the config file below in config.yaml. then run the following:
```
kubeadm init --config config.yaml --upload-certs --ignore-preflight-errors swap
```
make note of the `kubeadm join` commands init provides. we'll be using those later

### config file
```yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "0.0.0.0"
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: "v1.22.2"
controlPlaneEndpoint: "k8s-services.k8s.stonewall.lan:6443"
apiServer:
  certSANs:
    - "129.21.49.27"
    - "k8s.galenguyer.com"
    - "k8s.antifausa.net"
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
failSwapOn: false
podCIDR: "10.244.0.0/16"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "iptables"
conntrack:
  maxPerCore: 0
  tcpEstablishedTimeout: 0s
  tcpCloseWaitTimeout: 0s
```

i use calico as a cni. download the manifest from [https://docs.projectcalico.org/manifests/calico.yaml](https://docs.projectcalico.org/manifests/calico.yaml). find the mount for /sys/fs and comment it out. that's needed for ebpf, which we have disabled by default. 

## longhorn
longhorn needs things to be done to the volume lol. add the following to `/etc/rc.local` and then `chmod +x /etc/rc.local`
```bash
#!/bin/bash
mount --make-shared /
exit
```
run `mount --make-rshared /` on each node

after that you can install longhorn

## nfs
enable nfs mounting through the proxmox web ui, that's the easiest way probably
