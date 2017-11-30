This repo describes a docker image that will back up openshift pods.

The docker image is based on Alpine and has the openshift origin cli baked in.

Currently supported:
  - etcd
  - mysql
  - local content (via rsync)
  - mongodb


Prerequisites:

You can use the backup.yaml file to create the required openshift resources:

oc new-project infra-backups
oc process -f backup.yaml | oc create -n infra-backups -f -

Ensure that the newly created serviceaccount has the cluster-reader cluster-role and the system:image-puller role

oc policy add-role-to-user system:image-puller system:serviceaccount:infra-backups:backup
oc policy add-cluster-role-to-user cluster-reader system:serviceaccount:infra-backups:backup


To rebuild the docker image:

docker login docker-registry.fhpaas.fasthosts.co.uk:443
./build_and_push.sh
