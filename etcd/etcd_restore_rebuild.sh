#!/bin/bash
#
# MIT License
#
# (C) Copyright 2022-2023 Hewlett Packard Enterprise Development LP
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

main() {
    if [[ $restore_all == 1 ]]
    then
        clusters=$(kubectl get statefulsets.apps -A | grep bitnami-etcd | awk '{print $2}' | sed s/-bitnami-etcd//g)

        echo "Would you like to restore/rebuild ALL etcd clusters?"
        echo "The following etcd clusters will be restored/rebuilt:"
	echo ""
        echo $clusters
	echo ""
        echo "You will be accepting responsibility for any missing data if there is a"
        echo "restore/rebuild over a running etcd k/v. HPE assumes no responsibility."
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
        check_clusters_exist "${clusters}"
        echo "The following etcd clusters will be restored/rebuilt:"
        echo ""
        echo $clusters
        echo ""
        echo "You will be accepting responsibility for any missing data if there is a"
        echo "restore/rebuild over a running etcd k/v. HPE assumes no responsibility."
        echo "Proceed restoring/rebuilding? (yes/no)"
        read ans; echo
        if [[ $ans == 'yes' ]]
        then
            echo "Proceeding: restoring/rebuilding etcd clusters."
            check_for_backups "$clusters"
        else
            echo "Exiting"
            exit 0
        fi
    else
        echo "Specify which clusters to restore/rebuild. Options: '-a' all, '-m <clusters>' multiple clusters (e.g. cray-bos,cray-bss), '-s <cluster>' single cluster (e.g. cray-bos)."
    fi
}

restore() {
    cluster=$1
    # backup ==> for example: cray-bss/etcd.backup_2022-06-01-16-10-11
    backup=$2
    echo; echo " ----- Restoring from $backup ----- "
    clust_backup=$(echo $backup | sed 's/\// /g') # replace '/' with space ==> cray-bss etcd.backup_2022-06-01-16-10-11
    /opt/cray/platform-utils/etcd/etcd-util.sh restore_from_backup ${clust_backup}
    echo
    echo "Checking endpoint health."
    check_endpoint_health $cluster
    echo
}

check_endpoint_health() {
    cluster=$1
    ns=$(kubectl get statefulset -A -o json | jq --arg name "${cluster}-bitnami-etcd" '.items[].metadata | select (.name==$name) | .namespace' | sed 's/\"//g')
    pods=$(kubectl get endpoints ${cluster}-bitnami-etcd -n ${ns} -o json | jq -r .subsets[].addresses[].targetRef.name)
    for pod in $pods
    do
      #
      # ensure we get endpoint health success from at least
      # one pod.  Both rebuild and restore wait for the statefulset
      # rollout to complete, so we don't need to hit each pod.  Also
      # once the rebuild/restore is done, there's another rollout restart
      # of the pods when the cluster is set to an 'existing' state,
      # so at least one pod is already restarting at this point.
      #
      kubectl -n ${ns} exec -it -c etcd ${pod} -- /bin/sh -c "etcdctl endpoint health -w json" 2>&1 > /dev/null
      if [[ $? == 0 ]]; then
        success=1
        echo "${cluster} etcd cluster health verified from $pod"
	break
      fi
    done

    if [[ $success -eq 0 ]]; then
        echo "Error: ${cluster} endpoint unhealthy"
    fi
}

rebuild() {
    # $1: cluster ==> for example: cray-bss
    cluster=$1

    echo; echo " ----- Rebuilding $cluster ----- "
    /opt/cray/platform-utils/etcd/etcd-util.sh rebuild_cluster ${cluster}

    echo "Checking endpoint health."
    check_endpoint_health $cluster
    echo
}

prompt_to_rebuild() {
    echo "The following etcd clusters did not have backups so they will need to be rebuilt:"
    echo $1
    echo "Would you like to proceed rebuilding all of these etcd clusters? (yes/no)"
    read ans; echo
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
        temp=$(kubectl get statefulsets.apps -A -o json | jq --arg cname "${clust}-bitnami-etcd" '.items[].metadata | select(.name==$cname)') 
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

check_for_backups() {
    to_rebuild=""

    for cluster in $1
    do
      backups=$(/opt/cray/platform-utils/etcd/etcd-util.sh list_backups ${cluster} 2> /dev/null)
      if [[ "$backups" != *"No backups found"* ]] && [[ ! -z $backups ]]; then
        most_recent_backup=$(echo "$backups" | tail -n1)
        #
        # list_backups returns in date order, so we just need to pick
	# the last one (and remove the mysterious carriage return).
        #
        most_recent_backup=$(echo $most_recent_backup | sed 's/\r$//')
        restore ${cluster} $most_recent_backup
      else
        to_rebuild="${to_rebuild} ${cluster}"
      fi
    done

    if [[ $to_rebuild != "" ]]; then
        prompt_to_rebuild "$to_rebuild"
    fi
}

# --- main --- #
main

exit 0
