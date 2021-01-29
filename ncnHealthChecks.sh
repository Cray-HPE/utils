#!/bin/bash

# Copyright 2020-2021 Hewlett Packard Enterprise Development LP
#
# The ncnHealthChecks script executes a number of NCN system health checks:
#    Report Cray release info
#    Report Kubernetes status for Master and worker nodes
#    Report Ceph health status
#    Report health of Etcd clusters in services namespace
#    Report the number of pods on which worker node for each Etcd cluster
#    List automated Etcd backups for BOS, BSS, CRUS and DNS 
#    Report ncn node uptimes
#    Report worker ncn node pod counts
#    Report pods yet to reach the running state
#
# Returned results are not verified. Information is provided to aide in
# analysis of the results.
#
# The ncnHealthChecks script can be run on any worker or master ncn node from
# any directory. The ncnHealthChecks script can be run before and after an 
# NCN node is rebooted.
#

echo "             +++++ NCN Health Checks +++++"
echo "=== Can be executed on any worker or master ncn node. ==="
hostName=$(hostname)
echo "=== Executing on $hostName, $(date) ==="

echo
echo "=== Check Kubernetes' Master and Worker Node Status. ==="
echo "=== Verify Kubernetes' Node \"Ready\" Status and Version. ==="
date
kubectl get nodes -o wide
echo

echo
echo "=== Check Ceph Health Status. ==="
echo "=== Verify \"health: HEALTH_OK\" Status. ==="
echo "=== At times a status of HEALTH_WARN, too few PGs per OSD, and/or large \
omap objects, may be okay. ==="
echo "=== date; ssh ncn-s001 ceph -s; ==="
date
sshOptions="-q -o StrictHostKeyChecking=no"
ssh $sshOptions ncn-s001 ceph -s

echo
echo "=== Check the Health of the Etcd Clusters in the Services Namespace. ==="
echo "=== Verify a \"healthy\" Report for Each Etcd Pod. ==="
date;
for pod in $(kubectl get pods -l app=etcd -n services \
		     -o jsonpath='{.items[*].metadata.name}')
do
    echo "### ${pod} ###"
    kubectl -n services exec ${pod} -- /bin/sh -c "ETCDCTL_API=3 etcdctl endpoint health"
done
echo

echo
echo "=== Check the Number of Pods in Each Cluster. Verify they are Balanced. ==="
echo "=== Each cluster should contain at least three pods, but may contain more. ==="
echo "=== Ensure that no two pods in a given cluster exist on the same worker node. ==="
date
for ns in services
do
    for cluster in $(kubectl get etcdclusters.etcd.database.coreos.com \
                             -n $ns | grep -v NAME | awk '{print $1}')
    do
        kubectl get pod -n $ns -o wide | grep $cluster; echo ""
    done
done

echo
echo "=== Check if any \"alarms\" are set for any of the Etcd Clusters in the \
Services Namespace. ==="
echo "=== An empty list is returned if no alarms are set ==="
for pod in $(kubectl get pods -l app=etcd -n services \
                     -o jsonpath='{.items[*].metadata.name}')
do
    echo "### ${pod} Alarms Set: ###"
    kubectl -n services exec ${pod} -- /bin/sh \
            -c "ETCDCTL_API=3 etcdctl alarm list"
done

echo
echo "=== Check the health of Etcd Cluster's database in the Services Namespace. ==="
echo "=== PASS or FAIL status returned. ==="
for pod in $(kubectl get pods -l app=etcd -n services \
                     -o jsonpath='{.items[*].metadata.name}')
do
    echo "### ${pod} Etcd Database Check: ###"
    dbc=$(kubectl -n services exec ${pod} -- /bin/sh \
                  -c "ETCDCTL_API=3 etcdctl put foo fooCheck && \
                  ETCDCTL_API=3 etcdctl get foo && \
                  ETCDCTL_API=3 etcdctl del foo && \
                  ETCDCTL_API=3 etcdctl get foo" 2>&1)
    echo $dbc | awk '{ if ( $1=="OK" && $2=="foo" && \
                       $3=="fooCheck" && $4=="1" && $5=="" ) print \
    "PASS:  " PRINT $0; 
    else \
    print "FAILED DATABASE CHECK - EXPECTED: OK foo fooCheck 1 \
    GOT: " PRINT $0 }'
done

echo
echo "=== Etcd Clusters with Automatic Etcd Back-ups Configured: ==="
echo "=== BOS, BSS, CRUS, DNS and FAS ==="
echo "=== May want to ensure that automated back-ups are up to-date ==="
echo "=== and that automated back-ups continue after NCN worker reboot. ==="
echo "=== Clusters without Automated Backups: ==="
echo "=== HBTD, HMNFD, REDS, UAS & CPS ==="
echo "=== date; kubectl exec -it -n operators \$(kubectl get pod -n operators \
| grep etcd-backup-restore | head -1 | awk '{print \$1}') -c boto3 -- \
list_backups \"\"; ==="
date
kubectl exec -it -n operators $(kubectl get pod -n operators | \
grep etcd-backup-restore | head -1 | awk '{print $1}') -c boto3 -- list_backups ""
date
echo

echo;
echo "=== NCN node uptimes: ==="
echo "=== date; for h in ncn-w00{1,2,3} ncn-s00{1,2,3} ncn-m00{1,2,3}; do echo\
 "\$h:"; ssh \$h uptime; done ==="
date; for h in ncn-w00{1,2,3} ncn-s00{1,2,3} ncn-m00{1,2,3}; \
      do echo "$h:"; ssh $sshOptions $h uptime; done
echo;

echo;
echo "=== Worker ncn node pod counts: ==="
echo "=== date; kubectl get pods -A -o wide | grep -v Completed | grep w001 | wc -l ==="
date; kubectl get pods -A -o wide | grep -v Completed | grep w001 | wc -l
echo;
echo "=== date; kubectl get pods -A -o wide | grep -v Completed | grep w002 | wc -l ==="
date; kubectl get pods -A -o wide | grep -v Completed | grep w002 | wc -l
echo;
echo "=== date; kubectl get pods -A -o wide | grep -v Completed | grep w003 | wc -l ==="
date; kubectl get pods -A -o wide | grep -v Completed | grep w003 | wc -l
echo;

echo
echo "=== Pods yet to reach the running state: ==="
echo "=== kubectl get pods -A -o wide | grep -v \"Completed\|Running\" ==="
date
kubectl get pods -A -o wide | grep -v "Completed\|Running"
echo
echo
