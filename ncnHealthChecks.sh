#!/bin/bash

# Copyright 2020 Hewlett Packard Enterprise Development LP
#
# The ncnHealthCheck script executes a number of NCN system health checks:
#    Report Cray release info
#    Report Kubernetes status for Master and worker nodes
#    Report Ceph health status
#    Report health of Etcd clusters in services namespace
#    Report health of Etcd clusters in the vault namespace
#    Report the number of pods on which worker node for each Etcd cluster
#    List automated Etcd backups for BOS, BSS, CRUS DNS, Slingshot Controlleres and Vault
#    Report BGP peering status
#
# Returned results are not verified. Information is provided to aide in
# analysis of the results.
#
# The ncnHealthChecks script can be run on ncn-w001 from any directory. If
# checking the BGP peering status is not required, it can also be run
# on one of the master NCNs. The ncnHealthChecks script can be run before
# and after an NCN has been rebooted.
#

echo "             +++++ NCN Health Checks +++++"
echo "=== Can Be Executed on ncn-w001, or One of the Master NCN Nodes If Not Checking BGP Peering Status. ==="
hostName=$(hostname)
echo "=== Executing on $hostName, $(date) ==="

echo
echo "=== Cray Release Data ===="
cat /etc/cray-release
echo

echo
echo "=== Check Kubernetes' Master and Worker Node Status ==="
echo "=== Verify Kubernetes' Node \"Ready\" Status and Version ==="
date
kubectl get nodes -o wide
echo

echo
echo "=== Check Ceph Health Status ==="
echo "=== Verify \"health: HEALTH_OK\" Status ==="
echo "=== At times a status of HEALTH_WARN, too few PGs per OSD, and/or large omap objects, may be okay ==="
date
ssh ncn-m001 ceph -s

echo
echo "=== Check the Health of the Etcd Clusters in the Services Namespace ==="
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
echo "=== Check the Health of the Etcd Clusters in the Vault Namespace with TLS Authentication ==="
echo "=== Verify a \"healthy\" Report for Each Vault Etcd Pod. ==="
date
for pod in $(kubectl get pods -l app=etcd -n vault -o jsonpath='{.items[*].metadata.name}')
do
    echo "### ${pod} ###"
    kubectl -n vault exec $pod  -- /bin/sh -c "ETCDCTL_API=3 etcdctl \
               --cacert /etc/etcdtls/operator/etcd-tls/etcd-client-ca.crt \
               --cert /etc/etcdtls/operator/etcd-tls/etcd-client.crt \
               --key /etc/etcdtls/operator/etcd-tls/etcd-client.key \
               --endpoints https://localhost:2379 endpoint health  endpoint health"
done
echo

echo
echo "=== Check the Number of Pods in Each Cluster. Verify they are Balanced. ==="
echo "=== Each cluster should contain at least three pods, but may contain more. ==="
echo "=== Ensure that no two pods in a given cluster exist on the same worker node. ==="
date

for ns in services vault
do
    for cluster in $(kubectl get etcdclusters.etcd.database.coreos.com \
                             -n $ns | grep -v NAME | awk '{print $1}')
    do
        kubectl get pod -n $ns -o wide | grep $cluster; echo ""
    done
done

echo
echo "=== Etcd Clusters with Automatic Etcd Back-ups Configured: ==="
echo "=== BOS, BSS, CRUS, DNS, Slingshot Controllers & Vault ==="
echo "=== May want to ensure that automated back-ups are up to-date ==="
echo "=== and that automated back-ups continue after NCN worker reboot. ==="
echo "=== Clusters without Automated Backups: ==="
echo "=== FAS, HBTD, HMNFD, REDS, UAS & CPS ==="
date
kubectl exec -it -n operators $(kubectl get pod -n operators | \
grep etcd-backup-restore | head -1 | awk '{print $1}') -c boto3 -- list_backups ""
date
echo

echo
echo "=== Check BGP Peering Status *** Must Be Executed on NCN-W001 *** ==="
echo "=== Verify That All Neighbor BGP Sessions Are Reported as \"ESTABLISHED\" ==="
echo "=== \"ansible-playbook /opt/cray/crayctl/ansible_framework/main/spine-bgp-status.yml\" =="
echo "=== If Not, run the \"ansible-playbook /opt/cray/crayctl/ansible_framework/main/metallb-bgp-reset.yml\" ==="
echo "=== command to reset the sessions. After a couple of minutes run the spine-bgp-status.yml ==="
echo "=== play again to re-check BGP peering status. Repeat if necessary. ==="
date;
if [[ $hostName == "ncn-w001" ]]
then
    bgpSessionStatus=$(ansible-playbook /opt/cray/crayctl/ansible_framework/main/spine-bgp-status.yml 2>&1)
    echo "$bgpSessionStatus" | grep "result.stdout" -A 36 | tail -35
    echo
else
    echo "*** Executing on $hostName, not ncn-w001. Skipping BGP peering check. ***"
fi
echo




 
