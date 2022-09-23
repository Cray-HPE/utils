#!/bin/bash
#
# MIT License
#
# (C) Copyright 2022-2022 Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#

restore_all=0
while getopts s:m:ah stack
do
    case "${stack}" in
          s) etcd_to_restore=$OPTARG;;
          m) etcd_to_restore=$OPTARG;;
          a) restore_all=1;;
          h) echo "usage: etcd_restore_rebuild.sh -s <single_cluster> # Rebuilds/Restores a single cluster in a namespace"
	         echo "       etcd_restore_rebuild.sh -m <oneCluster,twoCluster,n_Cluster> # Rebuilds/Restores multiple clusters in a single namespace"
	         echo "       etcd_restore_rebuild.sh -a # Rebuilds/Restores all etcd clusters";;
	     \?) echo "usage: etcd_restore_rebuild.sh -s <single_cluster> # Rebuilds/Restores a single cluster in a namespace"
	         echo "       etcd_restore_rebuild.sh -m <oneCluster,twoCluster,n_Cluster> # Rebuilds/Restores multiple clusters in a single namespace"
	         echo "       etcd_restore_rebuild.sh -a # Rebuilds/Restores all etcd clusters";;
    esac
done

most_recent_backup=""
most_recent_backup_sec=""
current_date_sec=$(date +"%s")
one_week_sec=604800

main() {
    #create /root/etcd directory if it doesn't exist
    mkdir -p /root/etcd
    
    if [[ $restore_all == 1 ]]
    then
        clusters=$(kubectl get etcdclusters.etcd.database.coreos.com -A -o json | jq '.items[].metadata.name' | sed "s/\"//g")
        
        echo "Would you like to restore/rebuild ALL etcd clusters?"
        echo "The following etcd clusters will be restored/rebuilt:"
        echo $clusters; echo
        echo "You will be accepting responsibility for any missing data if there is a restore/rebuild over a running etcd k/v. HPE assumes no responsibility."
        echo "Proceed restoring/rebuilding all etcd clusters? (yes/no)"
        read ans; echo
        if [[ $ans == 'yes' ]]
        then
            echo "Proceeding: restoring/rebuilding all etcd clusters."
            check_for_backups "$clusters"
        else
            echo "Exiting"
            exit 0
        fi
    elif [[ ! -z $etcd_to_restore ]]
    then
        clusters=$(echo $etcd_to_restore | sed 's/,/ /g')
        # check that inputted clusters exits
        check_clusters_exist "${clusters}"
        echo "The following etcd clusters will be restored/rebuilt:"
        echo $clusters
        echo "You will be accepting responsibility for any missing data if there is a restore/rebuild over a running etcd k/v. HPE assumes no responsibility."
        echo "Proceed restoring/rebuilding? (yes/no)"
        read ans
        if [[ $ans == 'yes' ]]
        then
            echo "Proceeding: restoring/rebuilding etcd clusters."
            check_for_backups "$clusters"
        else
            echo "Exiting"
            exit 0
        fi
    else
        echo "Specify which clusters to restore/rebuild. Options: '-a' all, '-m <clusters>' multiple clusters (e.g. cray-bos-etcd,cray-bss-etcd), '-s <cluster>' single cluster (e.g. cray-bos-etcd)."
    fi
}

wait_for_running_pods_terminate() {
    # $1: cluster ==> for example: cray-bss-etcd
    # $2: namespace ==> for example: services
    cluster=$1
    namespace=$2
    running_pod_cnt=0
    pods_are_terminating='false'
    terminating_pod_cnt=0
    wait_terminating_cnt=0
    
    # If no pods are currently running, nothing to wait for:
    running_pod_cnt=$(kubectl get pods -l etcd_cluster=$cluster -n $namespace | awk '$3 == "Running" {print $3}' | wc -w)
    if (($running_pod_cnt == 0))
    then
        pods_are_terminating='noPodsFound'
        echo "- Any existing $cluster pods no longer in \"Running\" state."
        return
    fi
    
    # Wait for first terminating pod to avoid false positive on seeing
    # existing running pods in the cluster yet to be terminated:
    while [[ $terminating_pod_cnt -lt 1 && $wait_terminating_cnt -lt 40 ]]
    do
        terminating_pod_cnt=$(kubectl get pods -l etcd_cluster=$cluster -n $namespace | awk '$3 == "Terminating" {print $3}' | wc -w)
        echo "- Waiting for first terminating pod"
        wait_terminating_cnt=$(( $wait_terminating_cnt + 1 ))
        if [[ $terminating_pod_cnt -gt 0 ]]
        then
            pods_are_terminating='podsTerminating'
        fi
        sleep 3
    done
    if [[ $pods_are_terminating != 'podsTerminating' ]]
    then
        # Existing pods in the cluster failed to terminate.
        pods_are_terminating='errorTerminating'
    fi
}

wait_for_pods_start() {
    # $1: cluster ==> for example: cray-bss-etcd
    # $2: namespace ==> for example: services
    # $3: spec_size ==> for example: 3 from calling function
    #     Determined before restore or rebuild takes place.
    local cluster=$1
    namespace=$2
    spec_size=$3
    
    pods_started='false'
    waited_rounds=0
    previous_mem_ready=-1
    etcd_client=""
    
    echo "- Waiting for $spec_size $cluster pods to be running:"
    while [[ $waited_rounds -lt 20 && $pods_started == 'false' ]]
    do
        # Count number of running pods in the etcd cluster.
        # Compare to the expected number of pods: 
        members_ready=$(kubectl get pods -l etcd_cluster=$cluster -n $namespace | awk '$3 == "Running" {print $3}' | wc -w)
        
        # Once one etcd pod is running, verify etcd client pod exists:
        if [[ $members_ready -gt 0 && -z $etcd_client ]]
        then
            # Verify that the etcd-client pod has been created:
            etcd_client=$(kubectl get all -n $namespace | \
                              awk 'NF == 6 && $1 + /^service\/'$cluster'-client/ && $2 == "ClusterIP" && $3 ~ /^[0-9]/ {print $1}')
            if [[ -z $etcd_client ]]
            then
                pods_started='noEtcdClient'
                return
            fi
        fi
        if [[ $spec_size -eq $members_ready ]]
        then
            pods_started='true'
        else
            sleep 10
            waited_rounds=$(( $waited_rounds + 1 ))
        fi
        if [[ $previous_mem_ready -ne $members_ready ]] 
        then 
            echo "- ${members_ready}/${spec_size}  Running"
            previous_mem_ready=$members_ready
        fi
    done
    if [[ $pods_started == 'false' ]]
    then
        pods_started='errorStarting'
    fi 
}

wait_for_pods_terminate() {
    # $1: cluster ==> for example: cray-bss-etcd
    # $2: namespace ==> for example: services
    
    pods_terminated='false'
    waited_rounds=0
    while [[ $waited_rounds -lt 20 && $pods_terminated == 'false' ]]
    do
        test_empty=$(kubectl get pods -l etcd_cluster=${1} -n ${2} 2> /dev/null)
        if [[ -z $test_empty ]]
        then
            pods_terminated='true'
        else
            sleep 10
            waited_rounds=$(( $waited_rounds + 1 ))
        fi
    done
    if [[ $pods_terminated != 'true' ]]
    then
        echo "Error terminating $1 pods."
        pods_terminated='errorTerminating'
    fi
}

restore() {
    # $1: backup ==> for example: cray-bss/etcd.backup_2022-06-01-16-10-11
    echo; echo " ----- Restoring from $1 ----- "
    clust_backup=$(echo $1 | sed 's/\// /g') # replace '/' with space ==> cray-bss etcd.backup_2022-06-01-16-10-11
    etcd_cluster=$(echo $1 | cut -d '/' -f 1)'-etcd' # ==> cray-bss-etcd
    namespace=$(kubectl get etcdclusters.etcd.database.coreos.com -A -o json | jq --arg name "${etcd_cluster}" '.items[].metadata | select (.name==$name) | .namespace' | sed 's/\"//g')

    # First, get the spec size:
    spec_size=$(kubectl get etcd $etcd_cluster -n $namespace -o jsonpath='{.spec.size}')
    if (( $spec_size < 1 ))
    then
        echo "Error: spec.size reported as \"$spec_size\" - unable to determine the number of ${etcd_cluster} pods."
        return
    fi
    
    attempts=('zero' 'first' 'second' 'third' 'fourth')    
    client_pod='false'
    client_pod_loop_cnt=0
    max_client_pod_attempts=4
    # Loop and restore cluster again if cluster's client pod fails to be created:
    while [[ $client_pod == 'false' && $client_pod_loop_cnt -lt $max_client_pod_attempts ]]
    do
        # delete the etcd custom resource if one already exists
        kubectl -n $namespace delete etcdrestore.etcd.database.coreos.com/${etcd_cluster} 2>/dev/null
        
        #restore from latest backup
        kubectl exec -it -n operators $(kubectl get pod -n operators | grep etcd-backup-restore | head -1 | awk '{print $1}') -c util -- restore_from_backup ${clust_backup}
        if [[ $? != 0 ]]
        then
            echo
            echo "Error: Not able to restore from backup: ${clust_backup}."
            echo "Restoration of the ${etcd_cluster} cluster from $1 has failed."
            break
        fi
        
        # Wait for currently running pods to start terminating to avoid
        # false indication that newly created pods are already running:
        wait_for_running_pods_terminate $etcd_cluster $namespace
        if [[ $pods_are_terminating == "errorTerminating" ]]
        then
            echo
            echo "Error: Failed to detect that existing $etcd_cluster pods are terminating."
            echo "Restoration of the ${etcd_cluster} cluster from $1 has failed."
            break 
        fi
        
        # Wait for new cluster pods to reach running state.
        # Loop and do the restore again if etcd client pod not included with
        # restored etcd cluster pods:
        wait_for_pods_start $etcd_cluster $namespace $spec_size
        if [[ $pods_started == 'noEtcdClient' ]]
        then
            client_pod_loop_cnt=$((client_pod_loop_cnt + 1))
            echo
            echo "The ${etcd_cluster}-client service failed to be created on the ${attempts[$client_pod_loop_cnt]} attempt to restore the ${etcd_cluster} cluster."
            if (( $client_pod_loop_cnt < $max_client_pod_attempts ))
               then
                   echo "Proceeding with ${attempts[$((client_pod_loop_cnt +1))]} ${etcd_cluster} cluster restore attempt."
                   sleep 10
            fi
            echo 
        else
           client_pod='true' 
        fi
    done

    # Delete the etcd custom resource if one exists:
    kubectl -n $namespace delete etcdrestore.etcd.database.coreos.com/${etcd_cluster} 2>/dev/null
    echo $(date "+%Y-%m-%d-%H:%M:%S")
    if [[ $pods_started == 'true' ]]
    then
        echo "The ${etcd_cluster} cluster has successfully been restored from $1."
    elif [[ $pods_started == 'noEtcdClient' ]]
    then
        echo
        echo "The ${etcd_cluster}-client pod failed to be created after $client_pod_loop_cnt attempts to restore the ${etcd_cluster} cluster."
        echo "Error: Restoration of the ${etcd_cluster} cluster from $1 has failed."
    elif [[ $pods_started == 'errorStarting' ]]
    then
        echo
        echo "Error: Attempting to restore the ${etcd_cluster} cluster failed. Not all pods reached the \"Running\" state."
        echo "Restoration of the ${etcd_cluster} cluster from $1 has failed."
    fi
    echo
}

get_cluster() {
    if [[ $1 == "cray-externaldns-etcd" ]]
    then
        cluster="cray-externaldns-external-dns"
    else
        helm_chart=$(kubectl get etcd $1 -n $2 -o jsonpath='{.metadata.labels.helm\.sh/chart}')
        if [[ ! -z $helm_chart ]]
        then
            cluster=$(kubectl get deployment -n $2 -o json | jq --arg chart ${helm_chart} '.items[].metadata | .name as $name | .labels | select ( .["helm.sh/chart"]==$chart ) | $name' | sed "s/\"//g")
        fi
    fi
    
    if [[ -z $helm_chart ]]
    then
        echo "Unable to detect a corresponding service deployment paired with ${1}. Please enter cluster name. (e.g. when rebuilding cray-bos-etcd, enter: cray-bos)"
        read clust_name
        cluster=$clust_name
    fi
}

check_endpoint_health() {
    etcd_cluster=$1
    namespace=$2
    pods=$(kubectl get pods -l etcd_cluster=$etcd_cluster -n $namespace -o jsonpath='{.items[*].metadata.name}')
    pods_health='healthy'
    for pod in $pods
    do
        iter=0
        success=0
        # wait for endpoint to be healthy
	    while [[ $iter -lt 5 ]] && [[ $success -eq 0 ]]
	    do
            iter=$(( $iter + 1 ))
		    temp=$(kubectl -n services exec -it -c etcd ${pod} -- /bin/sh -c "ETCDCTL_API=3 etcdctl endpoint health -w json")
		    if [[ $? == 0 ]]
            then
                success=1
                echo "$pod - Endpoint reached successfully"
            else
		        echo "$pod - Could not reach endpoint. ${iter}/5 Attempts.   Will try again in 15 seconds."
		        sleep 15
            fi  
	    done
        if [[ $success -eq 0 ]]
	    then
    	    echo "Error: ${pod} endpoint unhealthy"
            pods_health='notHealthy'
	    fi
    done
}

rebuild() {
    # $1: cluster ==> for example: cray-bss-etcd
    etcd_cluster=$1
    echo; echo " ----- Rebuilding $etcd_cluster ----- "
    
    namespace=$(kubectl get etcdclusters.etcd.database.coreos.com -A -o json | jq --arg name "${etcd_cluster}" '.items[].metadata | select (.name==$name) | .namespace' | sed 's/\"//g')
    # get cluster name for deployment.
    # For example variable cluster will be set to: cray-bss
    get_cluster $etcd_cluster $namespace

    # First, get the spec size:
    spec_size=$(kubectl get etcd $etcd_cluster -n $namespace -o jsonpath='{.spec.size}')
    if (( $spec_size < 1 ))
    then
        echo "Error: spec.size reported as \"$spec_size\" - unable to determine the number of ${etcd_cluster} pods."
        return
    fi
    
    #capture deployments and etcd cluster objects
    kubectl -n $namespace get deployment ${cluster} -o yaml > /root/etcd/${cluster}.yaml
    if [[ $? != 0 ]]; then echo "Error: not able to get deployment ${cluster}."; return; fi
    kubectl -n $namespace get etcd ${etcd_cluster} -o yaml > /root/etcd/${etcd_cluster}.yaml
    if [[ $? != 0 ]]; then echo "Error: not able to get etcd ${etcd_cluster}."; return; fi
    echo "Deployment and etcd cluster objects captured in yaml file"
    
    # edit yaml
    python3 /opt/cray/platform-utils/etcd_restore_rebuild_util/edit_yaml_for_rebuild.py $cluster
    if [[ $? != 0 ]]; then echo "Error: not able to edit yaml at /root/etcd/${cluster}."; return; fi
    python3 /opt/cray/platform-utils/etcd_restore_rebuild_util/edit_yaml_for_rebuild.py $etcd_cluster
    if [[ $? != 0 ]]; then echo "Error: not able to edit yaml at /root/etcd/${etcd_cluster}."; return; fi
    echo "yaml files edited"
    
    # delete deployment and etcd cluster
    kubectl delete -f /root/etcd/${cluster}.yaml
    if [[ $? != 0 ]]; then echo "Error: not able to edit yaml at /root/etcd/${cluster}."; return; fi
    kubectl delete -f /root/etcd/${etcd_cluster}.yaml
    if [[ $? != 0 ]]; then echo "Error: not able to edit yaml at /root/etcd/${etcd_cluster}."; return; fi
    
    # wait for pods to terminate
    echo "Waiting for pods to terminate."
    wait_for_pods_terminate $etcd_cluster $namespace
    if [[ $pods_terminated == 'errorTerminating' ]]
    then
        echo "Error: not able to terminate ${etcd_cluster} pods."
        return
    fi
    
    # apply etcd cluster yaml and wait for pods to be Running
    kubectl -n $namespace apply -f /root/etcd/${etcd_cluster}.yaml
    if [[ $? != 0 ]]
    then
        echo "Error applying etcd cluster. Try to applying manually 'kubectl -n $namespace apply -f /root/etcd/${etcd_cluster}.yaml'"
        return
    fi
    
    echo "Waiting for pods to be 'Running'."
    wait_for_pods_start $etcd_cluster $namespace $spec_size
    if [[ $pods_started == 'noEtcdClient' ]]
    then
        echo "The ${etcd_cluster}-client pod failed to be created."
        return
    elif [[ $pods_started == 'errorStarting' ]]
    then
        echo "Error: not able to start ${etcd_cluster} pods."
        return
    fi
    
    # check endpoint health
    echo "Checking endpoint health."
    check_endpoint_health $etcd_cluster $namespace
    
    kubectl -n services apply -f /root/etcd/${cluster}.yaml
    if [[ $? != 0 ]]; then echo "Error: not able to apply cluster ${cluster}. Try to reapply."; fi
    echo $(date "+%Y-%m-%d-%H:%M:%S")
    if [[ $pods_health == 'notHealthy' ]]
    then
        echo "Error: Pods are not healthy after being rebuilt. Try rebuilding ${etcd_cluster} again."
    else
        echo "SUCCESSFUL REBUILD of the ${etcd_cluster} cluster completed."; echo
    fi

    # if it exists, silently delete old periodic-backup yaml. Allows 
    # top-of-the-hour cron job to create a new one for this latest restore.
    backup_name=$(kubectl get etcdbackup -n $namespace | awk 'NF > 1  && $1 + /^'$cluster'-etcd-cluster-periodic/ {print $1}')
    if [[ ! -z $backup_name ]]
    then
        kubectl delete etcdbackup -n services $backup_name
    fi
    echo
}

prompt_to_rebuild() {
    echo "The following etcd clusters did not have backups so they will need to be rebuilt:"
    echo $1
    echo "Would you like to proceed rebuilding all of these etcd clusters? (yes/no)"
    read ans
    if [[ $ans == "yes" ]]
    then 
        for clust in $1
        do
            rebuild $clust
        done
    else
        echo "Not rebuilding any clusters."
    fi
}

check_clusters_exist()  {
    should_exit=0
    for clust in $1
    do
        temp=$(kubectl get etcdclusters.etcd.database.coreos.com -A -o json | jq --arg cname "${clust}" '.items[].metadata | select(.name==$cname)') 
        if [[ -z $temp ]]
        then
            echo "This etcd cluster was not found, check spelling: ${clust}."
            should_exit=1
        fi
    done
    if [[ $should_exit -eq 1 ]]
    then
        echo "Exiting"
        exit 2
    fi
}

get_latest_backup() {
    most_recent_backup=""
    most_recent_backup_sec=""
    local backups="$1"
    
    for backup_instance in $backups
    do
        if [[ $most_recent_backup == "" ]]
        then
            most_recent_backup=$backup_instance
            backup_date=$(echo $backup_instance | cut -d '_' -f 3 | sed "s/-/ /3")
            if [[ -z $backup_date ]]; then most_recent_backup_sec=0;
            else most_recent_backup_sec=$(date -d "${backup_date}" "+%s"); fi
        else
            backup_date=$(echo $backup_instance | cut -d '_' -f 3 | sed "s/-/ /3")
            if [[ -z $backup_date ]]; then backup_sec=0;
            else backup_sec=$(date -d "${backup_date}" "+%s"); fi
            if [[ $backup_sec -gt $most_recent_backup_sec ]]
            then
                most_recent_backup=$backup_instance
                most_recent_backup_sec=$backup_sec
            fi
        fi
    done
    # Remove the '\r' carriage return at the end of the backup instance.
    # The '\r' is included in the etcd-backup-restore operator's output:
    # most_recent_backup=$'cray-bss/etcd.backup_v261466_2022-07-25-16:51:43\r'
    # Can be seen when "set -x" is included here, or in the
    # check_for_backups() function.
    most_recent_backup=$(echo $most_recent_backup | sed 's/\r$//')
}

check_for_backups() {
    to_rebuild=""

    for etcd_cluster in $1
    do
        backups=$(kubectl exec -it -n operators $(kubectl get pod -n operators | grep etcd-backup-restore | head -1 | awk '{print $1}') -c boto3 -- list_backups ${etcd_cluster%-etcd} 2> /dev/null)
        
        if [[ "$backups" != *"KeyError: 'Contents'"* ]] && [[ ! -z $backups ]] # check if any backups exist
        then
            get_latest_backup "$backups"
            
            # restore from backup
            # check if backup is more than 7 days old
            if [[ $(( $current_date_sec - $most_recent_backup_sec )) -gt $one_week_sec ]] 
            then
                echo "You are restoring a backup that is older than 7 days. The backup is ${most_recent_backup}"
                echo "Do you wish to proceed restoring? (yes/no)"
                read ans_rebuild
                if [[ $ans_rebuild == 'yes' ]]
                then
                    restore $most_recent_backup
                else
                    # if not restoring, rebuild
                    to_rebuild="${to_rebuild} ${etcd_cluster}"
                fi
            else
                restore $most_recent_backup
            fi
        else
            to_rebuild="${to_rebuild} ${etcd_cluster}"
        fi
    done
    
    if [[ $to_rebuild != "" ]]
    then
        prompt_to_rebuild "$to_rebuild"
    fi
}

# --- main --- #
main

exit 0
