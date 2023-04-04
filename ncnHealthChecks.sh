#!/bin/bash

# Copyright 2020-2023 Hewlett Packard Enterprise Development LP
#
# The ncnHealthChecks script executes a number of NCN system health checks:
#    Report Kubernetes status for Master and worker nodes
#    Report Ceph health status
#    Report health of Etcd clusters in services namespace
#    Report the number of pods on which worker node for each Etcd cluster
#    Report any "alarms" set for any of the Etcd clusters
#    Report health of Etcd cluster's database
#    List automated Etcd backups for BOS, BSS, CRUS, and FAS
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
# Set a delay of 15 seconds for use with timeout and ssh commands:
Delay=${Delay:-15}
sshOptions="-q -o StrictHostKeyChecking=no -o ConnectTimeout=$Delay"

while getopts s:h stack
do
    case "${stack}" in
        s) single_test=$OPTARG;;
        h) echo "usage: ncnHealthCheck.sh  # run all ncnHealthChecks"
     	   echo "     ncnHealthCheck.sh -s <health_check_name> # run a specific health check"
	   echo "     (-s options are   node_status, ceph_health_status, etcd_health_status, etcd_cluster_balance, etcd_alarm_check, etcd_database_health, etcd_backups_check, \
ncn_uptimes, node_resource_consumption, no_wipe_status, node_pod_counts, pods_not_running)"
           exit 1;;
       \?) echo "usage: ncnHealthCheck.sh  # run all ncnHealthChecks"
           echo "     ncnHealthCheck.sh -s <health_check_name> # run a specific health check"
           echo "     (-s options are   node_status, ceph_health_status, etcd_health_status, etcd_cluster_balance, etcd_alarm_check, etcd_database_health, etcd_backups_check, \
ncn_uptimes, node_resource_consumption, no_wipe_status, node_pod_counts, pods_not_running)"
           exit 1;;
    esac
done

function get_token() {
  cnt=0
  TOKEN=""
  endpoint="https://api-gw-service-nmn.local/keycloak/realms/shasta/protocol/openid-connect/token"
  client_secret=$(kubectl get secrets admin-client-auth -o jsonpath='{.data.client-secret}' | base64 -d)
  while [ "$TOKEN" == "" ]; do
    cnt=$((cnt+1))
    TOKEN=$(curl -k -s -S -d grant_type=client_credentials -d client_id=admin-client -d client_secret=$client_secret $endpoint)
    if [[ "$TOKEN" == *"error"* ]]; then
      TOKEN=""
      if [ "$cnt" -eq 5 ]; then
        break
      fi
      sleep 5
    else
      TOKEN=$(echo $TOKEN | jq -r '.access_token')
      break
    fi
  done
  echo $TOKEN
}

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
    # Get master nodes:
    mNcnNodes=$(kubectl get nodes --selector='node-role.kubernetes.io/master' \
                        --no-headers=true | awk '{print $1}' | tr "\n", " ")

    # Get worker nodes:
    wNcnNodes=$(kubectl get node --selector='!node-role.kubernetes.io/master' \
                        --no-headers=true | awk '{print $1}' | tr "\n", " ")

    # Get reachable master node
    goodMaster=""
    for master in $mNcnNodes; do
      if ping -c 1 -n -w 1 $master &> /dev/null; then
        goodMaster=$master
        break
      fi
    done

    if [ -z "$goodMaster" ]; then
      echo " --- FAILED --- Unable to reach any master node.";
      failureMsg="${failureMsg}\nFAIL: Unable to reach any master node."
      exit_code=1
    fi

    # Get storage nodes:
    sNcnNodes=$(ssh $sshOptions $goodMaster ceph node ls osd | \
                    jq -r 'keys | join(" ")')

    ncnNodes=${mNcnNodes}${wNcnNodes}$sNcnNodes
    echo "=== NCN Master nodes: ${mNcnNodes}==="
    echo "=== NCN Worker nodes: ${wNcnNodes}==="
    echo "=== NCN Storage nodes: $sNcnNodes ==="
    echo
}

node_status() {
    echo "**************************************************************************"
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
    echo "**************************************************************************"
    echo
    echo "=== Check Ceph Health Status. ==="
    echo "=== Verify \"health: HEALTH_OK\" Status. ==="
    if [ -z "$goodMaster" ]; then
      echo " --- FAILED --- Unable to get Ceph's health status without reachable master node.";
      failureMsg="${failureMsg}\nUnable to get Ceph's health status without reachable master node."
      exit_code=1
    else
      echo "=== At times a status of HEALTH_WARN, too few PGs per OSD, and/or large \
  omap objects, may be okay. ==="
      echo "=== date; ssh $goodMaster ceph -s; ==="
      date
      ssh $sshOptions $goodMaster ceph -s
      health_ok=$(ssh $sshOptions $goodMaster ceph -s | grep 'health: HEALTH_OK')
      if [[ -z $health_ok ]]; then
          echo " --- FAILED --- Ceph's health status is not \"HEALTH_OK\".";
          failureMsg="${failureMsg}\nFAIL: Ceph's health status is not \"HEALTH_OK\"."
          exit_code=1
      else
          echo " --- PASSED --- "; fi
      echo
    fi
}

etcd_health_status() {
    etcdHealthFail=0
    echo "**************************************************************************"
    echo
    echo "=== Check the Health of the Etcd Clusters in all Namespaces. ==="
    echo "=== Verify a \"healthy\" Report for Each Etcd Pod. ==="
    date;

    eps=$(kubectl get endpoints -A | grep bitnami-etcd | grep -v headless | awk '{print $2}')
    for ep in $eps; do
      ns=$(kubectl get statefulset -A -o json | jq --arg name "${ep}" '.items[].metadata | select (.name==$name) | .namespace' | sed 's/\"//g')
      for pod in $(kubectl get endpoints ${ep} -n ${ns} -o json | jq -r .subsets[].addresses[].targetRef.name)
      do
          echo "### ${pod} ###"
          timeout $Delay kubectl -n services exec ${pod} -c etcd -- /bin/sh -c \
                  "etcdctl endpoint health"; if [[ $? -ne 0 ]]; \
                  then echo "FAILED - Pod Not Healthy"; etcdHealthFail=1; fi
      done
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
    echo "**************************************************************************"
    echo
    echo "=== Check the Number of Pods in Each Cluster. Verify they are Balanced. ==="
    echo "=== Each cluster should contain at least three pods, but may contain more. ==="
    echo "=== Ensure that no two pods in a given cluster exist on the same worker node. ==="
    etcdPodHealthFail=0
    date
    for ns in services
    do
        for cluster in $(kubectl get statefulsets.apps -A | grep bitnami-etcd | awk '{print $2}')
        do
            # check each cluster contains the correct number of pods
            kubectl get pod -n $ns -o wide | grep $cluster | grep -v snapshotter; echo ""
            num_pods=$(kubectl get pod -n $ns -o wide | grep $cluster | grep -v snapshotter | wc -l)
            expected_num_pods=$(kubectl get statefulset $cluster -n $ns -o jsonpath='{.spec.replicas}')
            if [[ $num_pods -ne $expected_num_pods ]]; then etcdPodHealthFail=1; echo "ERROR: incorrect number of pods running."; echo; fi
            # check that no two pods are on the same worker node
            wnodes=$(kubectl get pod -n $ns -o wide | grep $cluster | grep -v snapshotter | awk '{print $7}')
            for node in $wnodes
            do
                num_pods_per_node=$(echo $wnodes | grep -o $node | wc -l)
                if [[ $num_pods_per_node -gt 1 ]]; then etcdPodHealthFail=2; echo "ERROR: at least 2 pods running on the same node."; echo; fi
            done
        done
    done
    if [[ $etcdPodHealthFail -eq 1 ]]
    then
        echo " --- FAILED --- the incorrect number of pods is running in an etcd cluster.";
        failureMsg="${failureMsg}\nFAIL: the incorrect number of pods is running in an etcd cluster."
    elif [[ $etcdPodHealthFail -eq 2 ]]
    then
        echo " --- FAILED --- at least 2 etcd pods running on the same worker node, should be on separate nodes.";
        failureMsg="${failureMsg}\nFAIL: at least 2 etcd pods running on the same worker node, should be on separate nodes."
        exit_code=1
    else echo " --- PASSED --- "; fi
    echo
}

etcd_alarm_check() {
    echo "**************************************************************************"
    echo
    echo "=== Check if any \"alarms\" are set for any of the Etcd Clusters in all \
Namespaces. ==="
    echo "=== An empty list is returned if no alarms are set ==="
    etcdAlarmFail=0

    eps=$(kubectl get endpoints -A | grep bitnami-etcd | grep -v headless | awk '{print $2}')
    for ep in $eps; do
      ns=$(kubectl get statefulset -A -o json | jq --arg name "${ep}" '.items[].metadata | select (.name==$name) | .namespace' | sed 's/\"//g')
      for pod in $(kubectl get endpoints ${ep} -n ${ns} -o json | jq -r .subsets[].addresses[].targetRef.name)
      do
          echo "### ${pod} Alarms Set: ###"
          alarms=$(timeout $Delay kubectl -n ${ns} exec ${pod} -c etcd -- /bin/sh \
              -c "etcdctl alarm list"); if [[ $? -ne 0 ]];\
                  then echo "FAILED - Pod Not Healthy"; etcdAlarmFail=1; fi
          if [[ ! -z $alarms ]]; then echo $alarms; etcdAlarmFail=1; fi
      done
    done
    if [[ $etcdAlarmFail -eq 1 ]]
    then
        echo " --- FAILED --- at least one etcd cluster has alarms set.";
        failureMsg="${failureMsg}\nFAIL: at least one etcd cluster has alarms set or an unhealthy pod."
        exit_code=1
    else echo " --- PASSED --- "; fi
    echo
}

etcd_database_health() {
    echo "**************************************************************************"
    echo
    echo "=== Check the health of Etcd Cluster's database in the Services Namespace. ==="
    echo "=== PASS or FAIL status returned. ==="
    etcdDatabaseFail=0
    eps=$(kubectl get endpoints -A | grep bitnami-etcd | grep -v headless | awk '{print $2}')
    for ep in $eps; do
      ns=$(kubectl get statefulset -A -o json | jq --arg name "${ep}" '.items[].metadata | select (.name==$name) | .namespace' | sed 's/\"//g')
      for pod in $(kubectl get endpoints ${ep} -n ${ns} -o json | jq -r .subsets[].addresses[].targetRef.name)
      do
        echo "### ${pod} Etcd Database Check: ###"
        dbc=$(timeout  --preserve-status --foreground $Delay kubectl \
                    -n ${ns} exec ${pod} -c etcd -- /bin/sh \
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
    done
    if [[ $etcdDatabaseFail -eq 1 ]]
    then
        echo " --- FAILED --- at least one Etcd Cluster's database is unhealthy.";
        failureMsg="${failureMsg}\nFAIL: at least one Etcd Cluster's database is unhealthy."
        exit_code=1
    else echo " --- PASSED --- "; fi
    echo
}

etcd_backups_check() {
    echo "**************************************************************************"
    echo
    echo "=== List automated etcd backups on system. ==="
    echo "=== Etcd Clusters with Automatic Etcd Back-ups Configured: ==="
    echo "=== BOS, BSS, CRUS, and FAS ==="
    echo "=== May want to ensure that automated back-ups are up to-date ==="
    echo "=== and that automated back-ups continue after NCN worker reboot. ==="
    echo "=== Clusters without Automated Backups: ==="
    echo "=== HBTD, HMNFD, REDS, UAS & CPS ==="
    echo "=== Automatic backups generated after cluster has been running 24 hours. ==="
    echo "=== Backups can be listed as follows:"
    echo "=== % /opt/cray/platform-utils/etcd/etcd-util.sh list_backups cray-bos"
    backupHealthFail=0
    date
    current_date_sec=$(date +"%s")
    one_day_sec=86400
    for cluster in cray-bos cray-bss cray-crus cray-fas cray-uas-mgr
    do
        echo; echo "-- $cluster -- backups"
        backup_within_day=""
	backups=$(/opt/cray/platform-utils/etcd/etcd-util.sh list_backups ${cluster})
        if [[ "$backups" != *"No backups found"* ]] && [[ ! -z $backups ]] # check if any backups exist
        then
          backup_within_day=$(/opt/cray/platform-utils/etcd/etcd-util.sh has_recent_backup ${cluster} 1 | sed 's/\r$//')
	fi
        age=$(kubectl get statefulset ${cluster}-bitnami-etcd -n services -o jsonpath='{.metadata.creationTimestamp}')
        if [[ ! -z $age ]]
        then
            age_sec=$(date -d "${age}" "+%s")
            if [[ $(( $current_date_sec - $age_sec )) -gt $one_day_sec ]]; then
                if [ "$backup_within_day" == "Pass" ]; then
                    echo "PASS: backup found less than 24 hours old."
                else
                    echo "ERROR: Expected backup because $cluster is over 24 hours old (creationTimestamp: $age). Expected a backup created within the last 24 hours."
                    backupHealthFail=1
                fi
            else
                echo "$cluster is less than 24 hours old so no recent backups are expected (creationTimestamp: ${age})."
            fi
        else
            echo "ERROR: could not get statefulset ${cluster}-bitnami-etcd. Check that cluster is running."
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
    echo "**************************************************************************"
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
    echo "**************************************************************************"
    echo
    echo "=== NCN master and worker node resource consumption ==="
    echo "=== NCN Master nodes: ${mNcnNodes}==="
    echo "=== NCN Worker nodes: ${wNcnNodes}==="
    echo "=== date; kubectl top nodes ==="
    date;
    cpuMemoryFail=0
    kubectl top nodes 2> /dev/null
    nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
    for node in $nodes
    do
        node_data=$(kubectl top nodes $node 2> /dev/null | tail -1)
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
    echo "**************************************************************************"
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
    export TOKEN=$(get_token)
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
        if [[ $noWipeFail -eq 2 ]]
        then
            echo "$xName - unavailable"
            continue
        fi
        noWipe=""
        iter=0
        # Because we're using bootparameters instead of bootscript, this loop is likely no longer
        # necessary. However, it also doesn't hurt to have it.
        while [[ -z $noWipe && $iter -lt 5 ]]; do
            noWipe=$(curl -s -k -H "Authorization: Bearer ${TOKEN}" "https://api-gw-service-nmn.local/apis/bss/boot/v1/bootparameters?name=${xName}" | grep -o "metal.no-wipe=[01]")
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
        echo " --- FAILED --- Failed to get token, skipped metal.no-wipe checks. Could not verify no-wipe status.";
        failureMsg="${failureMsg}\nFAIL: Failed to get token, skipped metal.no-wipe check. Could not verify no-wipe status."
        exit_code=1
    else echo " --- PASSED ---"; fi
    echo
}

node_pod_counts() {
    echo "**************************************************************************"
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
    echo "**************************************************************************"
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
    echo "**************************************************************************"
    echo
    echo "NCN Health Check complete. Summary of failures and warnings is printed below."
    echo
    if [[ $failureMsg == "" ]]; then echo "No failures or warnings to report. All checks passed.";
    else
        echo -e " --- Failures and Warnings--- $failureMsg"
    fi
    echo
    echo "Two informative tests were run which checked 'NCN uptimes' and 'worker NCN node pod counts'. These results can be manually checked."
    echo
}

run_complete_health_check() {
    echo "             +++++ NCN Health Checks +++++"
    echo "=== Can be executed on any worker or master ncn node. ==="
    hostName=$(hostname)
    echo "=== Executing on $hostName, $(date) ==="
    csmVersion=$(kubectl -n services get cm cray-product-catalog \
                         -o jsonpath='{.data.csm}' 2>/dev/null |  \
                         yq r -j - 2>/dev/null | \
                         jq 'to_entries[] | select(.value.active==true) | .key' 2>/dev/null | tr -d '"')
    echo "=== Active CSM version:"
    echo "$csmVersion"
    echo
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
