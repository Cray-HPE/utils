#!/bin/bash

# Copyright 2020-2021 Hewlett Packard Enterprise Development LP
#
# The ncnHealthChecks script executes a number of NCN system health checks:
#    Report Kubernetes status for Master and worker nodes
#    Report Ceph health status
#    Report health of Etcd clusters in services namespace
#    Report the number of pods on which worker node for each Etcd cluster
#    Report any "alarms" set for any of the Etcd clusters
#    Report health of Etcd cluster's database
#    List automated Etcd backups for BOS, BSS, CRUS, DNS and FAS
#    Report ncn node uptimes
#    Report NCN master and worker node resource consumption
#    Report NCN node xnames and metal.no-wipe status
#    Report worker ncn node pod counts
#    Report pods yet to reach the running state
#
# Returned results are not verified. Information is provided to aide in
# analysis of the results.
#
# The ncnHealthChecks script can be run on any worker or master NCN node from
# any directory. The ncnHealthChecks script can be run before and after an
# NCN node is rebooted.
#

failureMsg=""
exit_code=0
# Set a delay of 15 seconds for use with timeout command:
Delay=15

while getopts s:h stack
do
    case "${stack}" in
          s) single_test=$OPTARG;;
          h) echo "usage: ncnHealthCheck.sh  # run all ncnHealthChecks"
      	         echo "       ncnHealthCheck.sh -s <health_check_name> # run a specific health check"
	         echo "       (-s options are   node_status, ceph_health_status, etcd_health_status, etcd_cluster_balance, etcd_alarm_check, etcd_database_health, etcd_backups_check, \
ncn_uptimes, node_resource_consumption, no_wipe_status, node_pod_counts, pods_not_running)"
             exit 1;;
	     \?) echo "usage: ncnHealthCheck.sh  # run all ncnHealthChecks"
	         echo "       ncnHealthCheck.sh -s <health_check_name> # run a specific health check"
	         echo "       (-s options are   node_status, ceph_health_status, etcd_health_status, etcd_cluster_balance, etcd_alarm_check, etcd_database_health, etcd_backups_check, \
ncn_uptimes, node_resource_consumption, no_wipe_status, node_pod_counts, pods_not_running)"
                exit 1;;
    esac
done

main() {
    if [[ ! -z $single_test ]]
    then
        if [[ $single_test ==  "ncn_uptimes" || $single_test == "node_resource_consumption" || $single_test == "no_wipe_status" || $single_test == "node_pod_counts" || $single_test == "ceph_health_status" ]]
        then get_nodes; fi
        $single_test
        if [[ $? -ne 0 ]]
        then 
            echo "(-s options are   node_status, ceph_health_status, etcd_health_status, etcd_cluster_balance, etcd_alarm_check, etcd_database_health, etcd_backups_check, \
ncn_uptimes, node_resource_consumption, no_wipe_status, node_pod_counts, pods_not_running)"
            exit 2; 
        fi
    else
        get_nodes
        run_complete_health_check
        print_end_statement
    fi
    exit $exit_code
}

get_nodes() {
    sshOptions="-q -o StrictHostKeyChecking=no"

    # Get master nodes:
    mNcnNodes=$(kubectl get nodes --selector='node-role.kubernetes.io/master' \
                        --no-headers=true | awk '{print $1}' | tr "\n", " ")

    # Get worker nodes:
    wNcnNodes=$(kubectl get node --selector='!node-role.kubernetes.io/master' \
                        --no-headers=true | awk '{print $1}' | tr "\n", " ")

    # Get first master node - should not be the PIT node:
    firstMaster=$(echo $mNcnNodes | awk '{print $1}')

    # Get storage nodes:
    sNcnNodes=$(ssh $sshOptions $firstMaster ceph node ls osd | \
                    jq -r 'keys | join(" ")')

    # Get first storage node:
    firstStorage=$(echo $sNcnNodes | awk '{print $1}')

    ncnNodes=${mNcnNodes}${wNcnNodes}$sNcnNodes
    echo "=== NCN Master nodes: ${mNcnNodes}==="
    echo "=== NCN Worker nodes: ${wNcnNodes}==="
    echo "=== NCN Storage nodes: $sNcnNodes ==="
}

node_status() {
    echo
    echo "=== Check Kubernetes' Master and Worker Node Status. ==="
    echo "=== Verify Kubernetes' Node \"Ready\" Status and Version. ==="
    date
    kubectl get nodes -o wide
    notReady=$(kubectl get nodes -o json | jq '.items[].status.conditions[] | select (.type=="Ready") | select(.status!="True")')
    if [[ ! -z $notReady ]]
    then 
        echo " --- FAILED --- not all nodes are \"Ready\" ";
        failureMsg="${failureMsg}\nFAIL: not all nodes are \"Ready\"."
        exit_code=1
    else echo " --- PASSED --- "; fi
    echo
}

ceph_health_status() {
    echo
    echo "=== Check Ceph Health Status. ==="
    echo "=== Verify \"health: HEALTH_OK\" Status. ==="
    echo "=== At times a status of HEALTH_WARN, too few PGs per OSD, and/or large \
    omap objects, may be okay. ==="
    echo "=== date; ssh $firstStorage ceph -s; ==="
    date
    ssh $sshOptions $firstStorage ceph -s
    health_ok=$(ssh $sshOptions $firstStorage ceph -s | grep 'health: HEALTH_OK')
    if [[ -z $health_ok ]]
    then
        echo " --- FAILED --- Ceph's health status is not \"HEALTH_OK\".";
        failureMsg="${failureMsg}\nFAIL: Ceph's health status is not \"HEALTH_OK\"."
        exit_code=1
    else echo " --- PASSED --- "; fi
    echo
}

etcd_health_status() {
    etcdHealthFail=0
    echo
    echo "=== Check the Health of the Etcd Clusters in the Services Namespace. ==="
    echo "=== Verify a \"healthy\" Report for Each Etcd Pod. ==="
    date;
    for pod in $(kubectl get pods -l app=etcd -n services \
                -o jsonpath='{.items[*].metadata.name}')
    do
        echo "### ${pod} ###"
        timeout $Delay kubectl -n services exec ${pod} -- /bin/sh -c \
                "ETCDCTL_API=3 etcdctl endpoint health"; if [[ $? -ne 0 ]]; \
                then echo "FAILED - Pod Not Healthy"; etcdHealthFail=1; fi
    done
    if [[ $etcdHealthFail -eq 1 ]]
    then
        echo " --- FAILED --- not all Etcd pods are \"healthy\" "
        failureMsg="${failureMsg}\nFAIL: not all Etcd pods are \"healthy\"."
        exit_code=1
    else echo " --- PASSED --- "; fi
    echo
}

etcd_cluster_balance() {
    echo
    echo "=== Check the Number of Pods in Each Cluster. Verify they are Balanced. ==="
    echo "=== Each cluster should contain at least three pods, but may contain more. ==="
    echo "=== Ensure that no two pods in a given cluster exist on the same worker node. ==="
    etcdPodHealthFail=0
    date
    for ns in services
    do
        for cluster in $(kubectl get etcdclusters.etcd.database.coreos.com \
                                -n $ns | grep -v NAME | awk '{print $1}')
        do
            # check each cluster contains the correct number of pods
            kubectl get pod -n $ns -o wide | grep $cluster; echo ""
            num_pods=$(kubectl get pod -n $ns -o wide | grep $cluster | wc -l)
            expected_num_pods=$(kubectl get etcd $cluster -n $ns -o jsonpath='{.spec.size}')
            if [[ $num_pods -ne $expected_num_pods ]]; then etcdPodHealthFail=1; echo "ERROR: incorrect number of pods running."; echo; fi
            # check that no two pods are on the same worker node
            wnodes=$(kubectl get pod -n $ns -o wide | grep $cluster | awk '{print $7}')
            for node in $wnodes
            do
                num_pods_per_node=$(echo $wnodes | grep -o $node | wc -l)
                if [[ $num_pods_per_node -gt 1 ]]; then etcdPodHealthFail=2; echo "ERROR: atleast 2 pods running on the same node."; echo; fi
            done
        done
    done
    if [[ $etcdPodHealthFail -eq 1 ]]
    then 
        echo " --- FAILED --- the incorrect number of pods is running in an etcd cluster.";
        failureMsg="${failureMsg}\nFAIL: the incorrect number of pods is running in an etcd cluster."
    elif [[ $etcdPodHealthFail -eq 2 ]]
    then
        echo " --- FAILED --- atleast 2 etcd pods running on the same worker node, should be on seperate nodes.";
        failureMsg="${failureMsg}\nFAIL: atleast 2 etcd pods running on the same worker node, should be on seperate nodes."
        exit_code=1
    else echo " --- PASSED --- "; fi
    echo
}

etcd_alarm_check() {
    echo
    echo "=== Check if any \"alarms\" are set for any of the Etcd Clusters in the \
    Services Namespace. ==="
    echo "=== An empty list is returned if no alarms are set ==="
    etcdAlarmFail=0
    for pod in $(kubectl get pods -l app=etcd -n services \
                        -o jsonpath='{.items[*].metadata.name}')
    do
        echo "### ${pod} Alarms Set: ###"
        alarms=$(timeout $Delay kubectl -n services exec ${pod} -- /bin/sh \
            -c "ETCDCTL_API=3 etcdctl alarm list"); if [[ $? -ne 0 ]];\
                then echo "FAILED - Pod Not Healthy"; etcdAlarmFail=1; fi
        if [[ ! -z $alarms ]]; then echo $alarms; etcdAlarmFail=1; fi
    done
    if [[ $etcdAlarmFail -eq 1 ]]
    then
        echo " --- FAILED --- atleast one etcd cluster has alarms set.";
        failureMsg="${failureMsg}\nFAIL: atleast one etcd cluster has alarms set or an unhealthy pod."
        exit_code=1
    else echo " --- PASSED --- "; fi
    echo
}

etcd_database_health() {
    echo
    echo "=== Check the health of Etcd Cluster's database in the Services Namespace. ==="
    echo "=== PASS or FAIL status returned. ==="
    etcdDatabaseFail=0
    for pod in $(kubectl get pods -l app=etcd -n services \
                        -o jsonpath='{.items[*].metadata.name}')
    do
        echo "### ${pod} Etcd Database Check: ###"
        dbc=$(timeout  --preserve-status --foreground $Delay kubectl \
                    -n services exec ${pod} -- /bin/sh \
                    -c "ETCDCTL_API=3 etcdctl put foo fooCheck && \
                    ETCDCTL_API=3 etcdctl get foo && \
                    ETCDCTL_API=3 etcdctl del foo && \
                    ETCDCTL_API=3 etcdctl get foo" 2>&1)
        output=$(echo $dbc | awk '{ if ( $1=="OK" && $2=="foo" && \
                        $3=="fooCheck" && $4=="1" && $5=="" ) print \
        "PASS:  " PRINT $0;
        else \
        print "FAILED DATABASE CHECK - EXPECTED: OK foo fooCheck 1 \
        GOT: " PRINT $0; }')
        echo $output
        status=$(echo $output | awk '{ print $1 }')
        if [[ $status != "PASS:" ]]; then etcdDatabaseFail=1; fi
    done
    if [[ $etcdDatabaseFail -eq 1 ]]
    then
        echo " --- FAILED --- atleast one Etcd Cluster's database is unhealthy.";
        failureMsg="${failureMsg}\nFAIL: atleast one Etcd Cluster's database is unhealthy."
        exit_code=1
    else echo " --- PASSED --- "; fi
    echo
}

etcd_backups_check() {
    echo
    echo "=== List automated etcd backups on system. ==="
    echo "=== Etcd Clusters with Automatic Etcd Back-ups Configured: ==="
    echo "=== BOS, BSS, CRUS, DNS and FAS ==="
    echo "=== May want to ensure that automated back-ups are up to-date ==="
    echo "=== and that automated back-ups continue after NCN worker reboot. ==="
    echo "=== Clusters without Automated Backups: ==="
    echo "=== HBTD, HMNFD, REDS, UAS & CPS ==="
    echo "=== Automatic backups generated after cluster has been running 24 hours. ==="
    echo "=== date; kubectl exec -it -n operators \$(kubectl get pod -n operators \
    | grep etcd-backup-restore | head -1 | awk '{print \$1}') -c boto3 -- \
    list_backups <cluster> ; ===" 
    backupHealthFail=0
    date
    current_date_sec=$(date +"%s")
    one_day_sec=86400
    for cluster in cray-bos cray-bss cray-crus cray-externaldns cray-fas
    do
        echo; echo "-- $cluster -- backups"
        backup_within_day=0
        backups=$(kubectl exec -it -n operators $(kubectl get pod -n operators | \
            grep etcd-backup-restore | head -1 | awk '{print $1}') -c boto3 -- list_backups ${cluster})
        if [[ "$backups" != *"KeyError: 'Contents'"* ]] && [[ ! -z $backups ]] # check if any backups exist
        then
            for backup in $backups
            do
                echo $backup
                backup_date=$(echo $backup | cut -d '_' -f 3 | sed "s/-/ /3")
                if [[ -z $backup_date ]]
                then
                    echo " -Check date manually. Unable to get date from backup: $backup "
                else
                    backup_sec=$(date -d "${backup_date}" "+%s")
                    if [[ -z $backup_sec ]]; then echo "unable to get date from backup name"; fi
                    if [[ ! -z $backup_sec && $(( $current_date_sec - $backup_sec )) -lt $one_day_sec ]] # check if backup is less that 24 hour old
                    then
                        backup_within_day=1
                    fi
                fi
            done
        fi
        # look at age of cluster
        age=$(kubectl get etcd ${cluster}-etcd -n services -o jsonpath='{.metadata.creationTimestamp}')
        if [[ ! -z $age ]]
        then
            age_sec=$(date -d "${age}" "+%s")
            if [[ $(( $current_date_sec - $age_sec )) -gt $one_day_sec ]]
            then
                if [[ $backup_within_day -eq 1 ]]
                then
                    echo "PASS: backup found less than 24 hours old."
                else
                    echo "ERROR: Expected backup because $cluster is over 24 hours old (creationTimestamp is $age). Expected a backup created within the last 24 hours."
                    backupHealthFail=1
                fi
            else
                echo "$cluster creationTimestamp is ${age}. $cluster is less than 24 hours old so no recent backups are expected. (If this is incorrect and cluster is older than stated, there is an error as no backup was found within the last 24 hours) "
            fi
        else
            echo "ERROR: could not get etcd ${cluster}-etcd. Check that cluster is running."
            backupHealthFail=1
        fi
    done
    if [[ $backupHealthFail -eq 1 ]]
    then
        echo " --- FAILED --- not all Etcd clusters had expected backups.";
        failureMsg="${failureMsg}\nFAIL: not all Etcd clusters had expected backups."
        exit_code=1
    else echo " --- PASSED --- "; fi
    echo
}

ncn_uptimes() {
    echo
    echo "=== NCN node uptimes ==="
    echo "=== NCN Master nodes: ${mNcnNodes}==="
    echo "=== NCN Worker nodes: ${wNcnNodes}==="
    echo "=== NCN Storage nodes: $sNcnNodes ==="
    echo "=== date; for n in $ncnNodes; do echo\
    "\$n:"; ssh \$n uptime; done ==="
    date;
    for n in $ncnNodes
    do
        echo "$n:";
        ssh $sshOptions $n uptime;
    done
    echo " --- This is an informative check. No pass or fail status to report. --- "
    echo
}

node_resource_consumption() {
    echo
    echo "=== NCN master and worker node resource consumption ==="
    echo "=== NCN Master nodes: ${mNcnNodes}==="
    echo "=== NCN Worker nodes: ${wNcnNodes}==="
    echo "=== date; kubectl top nodes ==="
    date;
    cpuMemoryFail=0
    kubectl top nodes
    nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
    for node in $nodes
    do
        node_data=$(kubectl top nodes $node | tail -1)
        cpu=$(echo $node_data | awk '{print $3}')
        cpu=${cpu%?}
        memory=$(echo $node_data | awk '{print $5}')
        memory=${memory%?}
        if [[ $cpu -gt 95 || $memory -gt 95 ]]
        then
        echo "Warning: $node CPU or Memory is over 95% of capacity. Check that this node is healthy and its resources have not reached maximum capacity."
        cpuMemoryFail=1
        fi
    done
    if [[ $cpuMemoryFail -eq 1 ]]
    then
        echo " --- FAILED --- some nodes have reached CPU or Memory capacity over 95%.";
        failureMsg="${failureMsg}\nFAIL: some nodes have reached CPU or Memory capacity."
        exit_code=1
    else echo " --- PASSED --- "; fi
    echo
}

no_wipe_status() {
    echo
    echo "=== NCN node xnames and metal.no-wipe status ==="
    echo "=== metal.no-wipe=1, expected setting - the client ==="
    echo "=== already has the right partitions and a bootable ROM. ==="
    echo "=== Note that before the PIT node has been rebooted into ncn-m001, ==="
    echo "=== metal.no-wipe status may not available. ==="
    echo "=== NCN Master nodes: ${mNcnNodes}==="
    echo "=== NCN Worker nodes: ${wNcnNodes}==="
    echo "=== NCN Storage nodes: $sNcnNodes ==="
    noWipeFail=0
    # Get token:
    export TOKEN=$(curl -k -s -S -d grant_type=client_credentials -d client_id=admin-client -d client_secret=`kubectl get secrets admin-client-auth -o jsonpath='{.data.client-secret}' | base64 -d` https://api-gw-service-nmn.local/keycloak/realms/shasta/protocol/openid-connect/token | jq -r '.access_token')
    if [[ -z $TOKEN ]]
    then
        echo "Failed to get token, skipping metal.no-wipe checks. "
        noWipeFail=2
    fi
    date;
    for ncn_i in $ncnNodes
    do
        echo -n "$ncn_i: "
        xName=$(ssh $sshOptions $ncn_i 'cat /etc/cray/xname')
        if [[ -z $xName ]]
        then
            echo "Failed to obtain xname for $ncn_i"
            continue;
        fi
        noWipe=""
        iter=0
        while [[ -z $noWipe && $iter -lt 5 ]]; do
            if [[ $ncn_i == "ncn-m001" ]]
            then
                macAddress=$(curl -s -k -H "Authorization: Bearer ${TOKEN}" "https://api-gw-service-nmn.local/apis/bss/boot/v1/bootscript?name=${xName}" | grep chain)
                macAddress=${macAddress#*mac=}
                macAddress=${macAddress%&arch*}
                noWipe=$(curl -s -k -H "Authorization: Bearer ${TOKEN}" "https://api-gw-service-nmn.local/apis/bss/boot/v1/bootscript?mac=${macAddress}&arch=x86" | grep -o metal.no-wipe=[01])
            else
                noWipe=$(curl -s -k -H "Authorization: Bearer ${TOKEN}" "https://api-gw-service-nmn.local/apis/bss/boot/v1/bootscript?name=${xName}" | grep -o metal.no-wipe=[01])
            fi
            if [[ -z $noWipe ]]; then sleep 3; fi
            iter=$(($iter + 1))
        done
        if [[ -z $noWipe ]]
        then
            noWipe='unavailable'
            noWipeFail=1
        else
            noWipeVal=$(echo $noWipe | cut -d "=" -f2)
            if [[ $noWipeVal -ne 1 ]]; then noWipeFail=1; fi
        fi
        echo "$xName - $noWipe"
    done
    if [[ $noWipeFail -eq 1 ]]
    then
        echo " --- FAILED --- metal.no-wipe status is not 1. (note: node_status = upgrade/rebuild, then metal.no-wipe=0 is valid)";
        failureMsg="${failureMsg}\nFAIL: metal.no-wipe status is not 1. (note: node_status = upgrade/rebuild, then metal.no-wipe=0 is valid)."
        exit_code=1
    elif [[ $noWipeFail -eq 2 ]]
    then
        echo " --- FAILED --- Failed to get token, skipped atleast one metal.no-wipe check.";
        failureMsg="${failureMsg}\nFAIL: Failed to get token, skipped metal.no-wipe check. Could not verify no-wipe status."
        exit_code=1
    else echo " --- PASSED ---"; fi
    echo
}

node_pod_counts() {
    echo
    echo "=== Worker ncn node pod counts ==="
    echo "=== NCN Worker nodes: ${wNcnNodes} ==="
    echo "=== date; kubectl get pods -A -o wide | grep -v Completed | grep ncn-XXX \
    | wc -l ==="
    date;
    for n in $wNcnNodes
    do
        echo -n "$n: ";
        kubectl get pods -A -o wide | grep -v Completed | grep $n | wc -l;
    done
    echo " --- This is an informative check. No pass or fail status to report. --- "
    echo
}

pods_not_running() {
    echo
    echo "=== Pods yet to reach the running state: ==="
    echo "=== kubectl get pods -A -o wide | grep -v \"Completed\|Running\" ==="
    date
    kubectl get pods -A -o wide | grep -v "Completed\|Running"
    lines=$(kubectl get pods -A -o wide | grep -v "Completed\|Running" | wc -l)
    if [[ $lines -gt 1 ]]
    then
        echo " --- WARNING --- not all pods are in a 'Running' or 'Completed' state.";
        failureMsg="${failureMsg}\nWARNING: not all pods are in a 'Running' or 'Completed' state."
        # this is a warning, exits with code=0
    else echo " --- PASSED ---"; fi
    echo
}

print_end_statement() {
    echo "NCN Health Check complete. Summary of failures and warnings is printed below."
    if [[ $failureMsg == "" ]]; then echo "No failures or warnings to report. All checks passed.";
    else
        echo -e " --- Failures and Warnings--- $failureMsg"
    fi
    echo
    echo "Two informative tests were run which checked 'NCN uptimes' and 'worker NCN node pod counts'. These results can be manually checked."
}


run_complete_health_check() {
    echo "             +++++ NCN Health Checks +++++"
    echo "=== Can be executed on any worker or master ncn node. ==="
    hostName=$(hostname)
    echo "=== Executing on $hostName, $(date) ==="
    # run all health checks
    node_status
    ceph_health_status
    etcd_health_status
    etcd_cluster_balance
    etcd_alarm_check
    etcd_database_health
    etcd_backups_check
    ncn_uptimes
    node_resource_consumption
    no_wipe_status
    node_pod_counts
    pods_not_running
}

# run main function
main
>>>>>>> 7813b2c (CASMPET-4396)
