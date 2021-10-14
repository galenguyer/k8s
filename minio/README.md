# minio

generate login creds with the following:
```
kubectl create secret -n minio generic minio-auth --from-literal=username=minio --from-literal=password=<YOUR PASSWORD>
```

then just apply the yaml file.

## everything below this line is shit lmao

### installation
installation seems easiest using the krew plugin and then the web ui. the web ui is kinda scuffed with authentication, use a private tab

install krew using the documentation provided at [https://krew.sigs.k8s.io/docs/user-guide/setup/install/](https://krew.sigs.k8s.io/docs/user-guide/setup/install/).

install the minio plugin with the following commands:
```
kubectl krew update
kubectl krew install minio
```

initialize the operator with `kubectl minio init`

to access the web ui, use the command `kubectl minio proxy -n minio-operator`. it will provide a jwt for you for authentication

latest version of minio dies on waiting for prometheus. version `minio/minio:RELEASE.2021-10-06T23-36-31Z.hotfix.c15e08bd2` works for me

make sure to save the credentials printed

you can watch the status of the deployment with `kubectl minio tenant info minio -n minio-tenant`

### namespace
apply [namespace.yaml](./namespace.yaml) to apply the label kubed needs to sync the certificate for the domain for the namespace.

### notes
the nfs share must have no_squash_root set else the logs pod won't be able to chown data

the minio postgres db password was wrong, leading to the log search pod failing. the fix is below:
```
kubectl exec -it -n minio-tenant minio-log-0 -- psql -c "ALTER ROLE postgres WITH PASSWORD '$(kubectl get secret -n minio-tenant minio-log-secret --output go-template='{{ .data.POSTGRES_PASSWORD | base64decode }}')';"
```
