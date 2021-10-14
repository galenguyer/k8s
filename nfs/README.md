# nfs

pulled from [kubernetes-sigs/nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner) because it's cool and easy to set up

## nfs server
if this is in an lxc container you'll need it to be priviliged and you'll have to add `lxc.apparmor.profile: unconfined` to the config file. 

install nfs-kernel-server

read this to set up nfsv4 [https://wiki.debian.org/NFSServerSetup](https://wiki.debian.org/NFSServerSetup)

add the following line to `/etc/exports`
```
/srv/nfs    192.168.8.0/24(rw,sync,no_subtree_check)
```
change the subnet if you have to

run `exportfs -a && systemctl restart nfs-server` to export stuff properly

you can use `showmount -e` to show all active mounts

if you're using different settings update the information in `deployment.yaml`

## testing
you can test the provisioner with the following pod and pvc:

```
kind: Pod
apiVersion: v1
metadata:
  name: test-pod
spec:
  containers:
  - name: test-pod
    image: busybox:stable
    command:
      - "/bin/sh"
    args:
      - "-c"
      - "touch /mnt/SUCCESS && exit 0 || exit 1"
    volumeMounts:
      - name: nfs-pvc
        mountPath: "/mnt"
  restartPolicy: "Never"
  volumes:
    - name: nfs-pvc
      persistentVolumeClaim:
        claimName: test-claim
---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: test-claim
spec:
  storageClassName: managed-nfs-storage
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Mi
```
