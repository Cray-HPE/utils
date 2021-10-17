#!/bin/bash

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

wait_for_pods_start() {
    pods_started='false'
    waited_rounds=0
    previous_mem_ready=-1
    spec_size=$(kubectl get etcd $1 -n $2 -o jsonpath='{.spec.size}')
    while [[ $waited_rounds -lt 20 && $pods_started == 'false' ]]
    do
        members_ready=$(kubectl get pods -l etcd_cluster=$1 -n $2 -o jsonpath='{.items[*].status.phase}' | grep "Running" | wc -w)
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
    if [[ $pods_started != 'true' ]]
    then
        pods_started='errorStarting'
    fi 
}

wait_for_pods_terminate() {
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
    echo; echo " ----- Restoring from $1 ----- "
    clust_backup=$(echo $1 | sed 's/\// /g') # replace '/' with space
    etcd_cluster=$(echo $1 | cut -d '/' -f 1)'-etcd'
    namespace=$(kubectl get etcdclusters.etcd.database.coreos.com -A -o json | jq --arg name "${etcd_cluster}" '.items[].metadata | select (.name==$name) | .namespace' | sed 's/\"//g')
    
    # delete the etcd custom resource if one already exists
    kubectl -n $namespace delete etcdrestore.etcd.database.coreos.com/${etcd_cluster} 2>/dev/null

    #restore from latest backup
    kubectl exec -it -n operators $(kubectl get pod -n operators | grep etcd-backup-restore | head -1 | awk '{print $1}') -c util -- restore_from_backup ${clust_backup}
    if [[ $? != 0 ]]; then echo "Error: not able to restore from backup: ${clust_backup}."; return; fi
    #wait for pods to come up
    wait_for_pods_start $etcd_cluster $namespace
    if [[ $pods_started == 'true' ]]
    then
        echo "Successfully restored ${etcd_cluster}"
        # delete the etcd custom resource
        kubectl -n $namespace delete etcdrestore.etcd.database.coreos.com/${etcd_cluster}
    elif [[ $pods_started == 'errorStarting' ]]
    then
        echo "Error: Attempted to restore ${etcd_cluster} but not all pods are 'ready'."
    else
        echo "Function wait_for_pods didn't work."
    fi
}

rebuild_vault() {
    # capture the yaml file
    kubectl -n vault get vault cray-vault -o yaml > /root/etcd/cray-vault.yaml
    if [[ $? != 0 ]]; then echo "Error: not able to caputre vault deployment in yaml file."; return; fi
    
    # edit yaml
    python3 edit_yaml_for_rebuild.py cray-vault
    if [[ $? != 0 ]]; then echo "Error: not able to edit vault yaml file."; return; fi
    
    # Delete the vault and the current unseal key and wait for the pods to terminate
    kubectl delete -f /root/etcd/cray-vault.yaml
    if [[ $? != 0 ]]; then echo "Error: not able to terminate pods."; return; fi
    kubectl -n vault delete secret cray-vault-unseal-keys
    if [[ $? != 0 ]]; then echo "Error: not able to delete vault secret."; return; fi
    
    # wait for pods to terminate
    wait_for_pods_terminate cray-vault-etcd vault
    if [[ $pods_terminated == 'errorTerminating' ]]; then echo "Error: not all vault pods terminated."; return; fi

    # apply the yaml
    kubectl apply -f /root/etcd/cray-vault.yaml
    if [[ $? != 0 ]]; then echo "Error: not able to apply vault."; return; fi

    # wait for pods to be 'running'
    wait_for_pods_start cray-vault-etcd vault
    if [[ $pods_started != 'true' ]]; then echo "Error: Attempted to restart cray-vault-etcd but not all pods are 'ready'. "; fi

    kubectl delete etcdbackup -n vault cray-vault-etcd-cluster-periodic-backup
    if [[ $? != 0 ]]; then echo "Error: could not delete existing backup definition 'cray-vault-etcd-cluster-periodic-backup'. Manually check cray-vault-etcd is running and manually delete backup definition."; fi
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
		    temp=$(kubectl -n services exec -it ${pod} -- /bin/sh -c "ETCDCTL_API=3 etcdctl endpoint health -w json")
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
    etcd_cluster=$1
    echo; echo " ----- Rebuilding $etcd_cluster ----- "
    if [[ $etcd_cluster == 'cray-vault-etcd' ]]
    then
        rebuild_vault
    else
        namespace=$(kubectl get etcdclusters.etcd.database.coreos.com -A -o json | jq --arg name "${etcd_cluster}" '.items[].metadata | select (.name==$name) | .namespace' | sed 's/\"//g')
        # gets cluster name for deployment
        get_cluster $etcd_cluster $namespace
        
        #capture deployments and etcd cluster objects
        kubectl -n $namespace get deployment ${cluster} -o yaml > /root/etcd/${cluster}.yaml
        if [[ $? != 0 ]]; then echo "Error: not able to get deployment ${cluster}."; return; fi
        kubectl -n $namespace get etcd ${etcd_cluster} -o yaml > /root/etcd/${etcd_cluster}.yaml
        if [[ $? != 0 ]]; then echo "Error: not able to get etcd ${etcd_cluster}."; return; fi
        echo "Deployment and etcd cluster objects captured in yaml file"
        
        # edit yaml
        python3 edit_yaml_for_rebuild.py $cluster
        if [[ $? != 0 ]]; then echo "Error: not able to edit yaml at /root/etcd/${cluster}."; return; fi
        python3 edit_yaml_for_rebuild.py $etcd_cluster
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
        if [[ $pods_terminated == 'errorTerminating' ]]; then echo "Error: not able to terminate ${etcd_cluster} pods."; return; fi
        
        # apply etcd cluster yaml and wait for pods to be Running
        kubectl -n $namespace apply -f /root/etcd/${etcd_cluster}.yaml
        if [[ $? != 0 ]]; then echo "Error applying etcd cluster. Try to applying manually 'kubectl -n $namespace apply -f /root/etcd/${etcd_cluster}.yaml'"; return; fi
        echo "Waiting for pods to be 'Running'."
        wait_for_pods_start $etcd_cluster $namespace
        if [[ $pods_started == 'errorStarting' ]]; then echo "Error: not able to start ${etcd_cluster} pods."; return; fi
        
        # check endpoint health
        check_endpoint_health $etcd_cluster $namespace
        kubectl -n services apply -f /root/etcd/${cluster}.yaml
        if [[ $? != 0 ]]; then echo "Error: not able to apply cluster ${cluster}. Try to reapply."; fi
        if [[ $pods_health == 'notHealthy' ]]
        then
            echo "Error: Pods are not healthy after being rebuilt. Try rebuilding ${etcd_cluster} again."
        else
            echo; echo "SUCCESSFUL REBUILD ${etcd_cluster}."; echo
        fi

        # delete existing etcd backup
        backup_name=$(kubectl get etcdbackup -n $namespace | grep "${cluster}.*periodic")
        if [[ ! -z $backup_name ]]
        then
            kubectl delete etcdbackup -n services $backup_name
        else
            echo "Could not find existing backup definition. If one exists, it should be deleted so a new one can be created that points to the new cluster IP."
            echo "Example delete command: groot-ncn-w001:~ # kubectl delete etcdbackup -n services cray-bos-etcd-cluster-periodic-backup"
        fi
    fi
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
    backups="$1"
    for backup_instance in $backups
    do
        if [[ $most_recent_backup == "" ]]
        then
            most_recent_backup=$backup_instance
            backup_date=$(echo $backup_instance | cut -d '_' -f 3 | sed "s/-/ /3")
            if [[ -z $backup_date ]]; then backup_sec=0;
            else backup_sec=$(date -d "${backup_date}" "+%s"); fi
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
}

check_for_backups() {
    to_rebuild=""

    for etcd_cluster in $1
    do
        backups=$(kubectl exec -it -n operators $(kubectl get pod -n operators | grep etcd-backup-restore | head -1 | awk '{print $1}') -c boto3 -- list_backups ${etcd_cluster%-etcd} 2> /dev/null)
        if [[ "$backups" != *"KeyError: 'Contents'"* ]] && [[ ! -z $backups ]] # check if any backups exist
        then
            get_latest_backup "$backups"
            #restore from backup
            if [[ $(( $current_date_sec - $most_recent_backup_sec )) -gt $one_week_sec ]] # check if backup is more than 7 days old
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
