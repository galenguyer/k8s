# k8s on unpriviliged lxc
note: nfs and longhorn won't work with this setup. you'll have to rely on local storage entirely. refer to [lxc](./lxc.md) for instructions on how to do this with priviliged lxc, with support for nfs and longhorn.

## setup
vnets, pfsense, and k8s-services are all the same

## host setup
read this: [https://kubernetes.io/docs/tasks/administer-cluster/kubelet-in-userns/](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-in-userns/)

because the kernel is shared we have to set some stuff up on your host instead of in a vm.
* `echo cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory systemd.unified_cgroup_hierarchy=1 > /boot/cmdline.txt`
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
    * `echo "fuse" > /etc/modules-load.d/fuse.conf`
    * `modprobe br_netfilter`
    * `modprobe overlay`
* add `net.bridge.bridge-nf-call-iptables=1` and `net.ipv4.ip_forward=1` to `/etc/sysctl.conf`
    * load settings with `sysctl --system`
* reboot

## k8s-template
create an unprivliged container with nesting enabled.

use the debian template

i'm doing a 16gb root disk to start, will expand if needed

4 cores, 4gb ram. **make sure you disable swap**

put it on your network, use dhcp so pfsense will give it an ip

add the following to the config file for the container:
```
lxc.mount.entry: /boot boot none bind,ro
lxc.mount.entry: /dev/fuse dev/fuse none bind,optional,create=file
lxc.cgroup.devices.allow: c 10:299 rwm
```

you can now attach from the host with `lxc-attach`

uncomment `en_US.UTF-8` from `/etc/locale.gen` and run `locale-gen`. run `echo LANG=en_US.UTF-8 > /etc/locale.conf`. also run `dpkg-reconfigure tzdata` to set the timezone

do an apt update and install the following packages: `gnupg2 curl apt-transport-https ca-certificates fuse-overlayfs`

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

add the following to `/etc/crio/crio.conf`
```bash
#/etc/crio/crio.conf
[crio]
  storage_driver = "overlay"
# Using non-fuse overlayfs is also possible for kernel >= 5.11, but requires SELinux to be disabled
  storage_option = ["overlay.mount_program=/usr/bin/fuse-overlayfs"]
```
run `echo _CRIO_ROOTLESS=1 >> /etc/default/crio`

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
kubeadm init --config config.yaml --upload-certs --ignore-preflight-errors=swap
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
featureGates:
  KubeletInUserNamespace: true
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
