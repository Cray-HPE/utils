#!/bin/bash
#
# Simple wrapper to exec into one of the etcd-backup-restore-* pods
# to perform various etcd admin activities.
#

kubectl exec -it -n services $(kubectl get po -n services -l 'app.kubernetes.io/name=cray-etcd-backup' -o jsonpath={.items[0].metadata.name}) -- /bin/sh -c "$*"
