#!/bin/bash

# Copyright 2020-2021 Hewlett Packard Enterprise Development LP
#
# For each postgres cluster, the ncnPostgresHealthChecks script determines
# the leader pod and reports the status of all postgres pods in the cluster.
#
# Returned results are not verified.
#
# The ncnPostgresHealthChecks script can be run on any worker or master ncn
# node from any directory. The ncnPostgresHealthChecks script can be run
# before and after an NCN node is rebooted.
#

echo "             +++++ NCN Postgres Health Checks +++++";
echo "=== Can Be Executed on any ncn worker or master node. ==="
hostName=$(hostname)
echo "=== Executing on $hostName, $(date) ==="

echo
echo "=== Postgresql Operator Version ==="
kubectl get pod -n services -l "app.kubernetes.io/name=postgres-operator" \
        -o jsonpath='{..image}' | xargs -n 1 | grep postgres | uniq

echo
echo "=== List of Postgresql Clusters Using Operator ==="
kubectl get postgresql -A
postgresClusters="$(kubectl get postgresql -A | awk '/postgres/ || NR==1' | \
                    grep -v NAME | awk '{print $1","$2}')"

echo
echo "=== Look at patronictl list info for each cluster, determine and attach \
to leader of each cluster ==="
echo "=== Report status of postgres pods in cluster ==="

dottedLine="------------------------------------------------------------------\
--------------------------------"
echo       "---${dottedLine}"
echo

for c in $postgresClusters
do
        # NameSpace and postgres cluster name
        c_ns="$(echo $c | awk -F, '{print $1;}')"
        c_name="$(echo $c | awk -F, '{print $2;}')"
        # Get postgres pods for this cluster name:
        members="$(kubectl get pod -n $c_ns -l "cluster-name=$c_name" \
                           -o custom-columns=NAME:.metadata.name --no-headers)"
        numMembers=$(echo "$members" | wc -l)
        	
	# Find the leader:
        for m in $members
        do
            leader="$(kubectl -n $c_ns exec $m -- patronictl list 2>/dev/null \
                      | awk ' $8 == "Leader" && $10 == "running" {print $4}')"
            if [ -n "$leader" ]
            then
                break;
            fi
        done
        if [ -z "$leader" ]
        then
            echo "=== ****** Did not find a leader for the $c_name cluster in \
$numMembers pods ****** ==="
            echo
            kubectl get pods -A -o wide | grep "NAME\|$c_name"
            other=$members
        else
            # Have a leader:
            echo "=== Looking at patronictl list info for the $c_name cluster \
with leader pod: $leader ==="
            
            other="$(echo $members | xargs -n 1 | grep -v $leader)"
            
            echo; echo "--- PSP for pod $leader ---"
            kubectl -n $c_ns get pod $leader -o yaml | grep "kubernetes.io/psp"
            
            echo; echo "--- patronictl list for $c_ns leader pod $leader ---"
            kubectl -n $c_ns exec $leader -- patronictl list 2>/dev/null
            kubectl get pods -A -o wide | grep "NAME\|$c_name"
            
            echo; echo "--- Logs for $c_ns leader pod $leader ---"
            kubectl logs -n $c_ns $leader postgres | \
                awk '{$1="";$2=""; print $line}' | egrep "INFO|ERROR" \
                | egrep -v "NewConnection|bootstrapping" | sort -u
        fi
        
        for o in $other
        do
            echo; echo "--- Logs for $c_ns non-leader pod $o ---"
            kubectl logs -n $c_ns $o postgres | awk '{$1="";$2=""; print $line}'\
                | egrep "INFO|ERROR" | egrep -v "NewConnection|bootstrapping" \
                | sort -u
        done
        echo;
        echo $dottedLine
        echo $dottedLine
        echo
done
echo "=== kubectl get pods -A -o wide | grep \"NAME\|postgres-\" |\
 grep -v \"operator\|Completed\" ==="
echo
kubectl get pods -A -o wide | grep "NAME\|postgres-" | grep -v "operator\|Completed"
echo
exit 0;


