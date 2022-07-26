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
# For each postgres cluster, the ncnPostgresHealthChecks script determines
# the leader pod and reports the status of all postgres pods in the cluster.
#
# Returned results are not verified.
#
# The ncnPostgresHealthChecks script can be run on any worker or master ncn
# node from any directory. The ncnPostgresHealthChecks script can be run
# before and after an NCN node is rebooted.
#

failureMsg=""
lagFlag=0

function printErrorLogs() {
    echo; echo "--- Error Logs for $c_ns \"Leader Pod\" $leader --- "
        kubectl logs -n $c_ns $leader postgres | awk '{print $line}' \
            | egrep "ERROR" | egrep -v "get_cluster|IncompleteRead\(0 bytes read\)" \
            | sort -u | tail -n 50

    for o in $other
    do
        echo; echo "--- Error Logs for $c_ns$podDescribe pod $o --- "
        kubectl logs -n $c_ns $o postgres | awk '{print $line}' \
            | egrep "ERROR" | egrep -v "get_cluster|IncompleteRead\(0 bytes read\)" \
            | sort -u | tail -n 50
    done

    echo; echo " * The logs above show up to 50 of the most recent errors * "
}


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
# check that all postgres clusters are 'Running'
if [[ ! -z $(kubectl get postgresql -A -o json | jq '.items[].status | select(.PostgresClusterStatus != "Running")') ]]; then
    echo "--- ERROR --- not all Postgresql Clusters have a status of 'Running'"
    failureMsg="${failureMsg}\nERROR: not all Postgresql Clusters have a status of 'Running'"
fi

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
    members="$(kubectl get pod -n $c_ns -l "cluster-name=$c_name,application=spilo" \
             -o custom-columns=NAME:.metadata.name --no-headers)"
    numMembers=$(echo "$members" | wc -l)
    # check 3 custer members for all (except 2 cluster members for sma-postgres-cluster)
    if [[ $c_name == "sma-postgres-cluster" ]]; then
      	if [[ $numMembers -ne 2 ]]; then
	    echo "--- ERROR --- $c cluster only has ${numMembers}/2 cluster members"
	    failureMsg="${failureMsg}\nERROR: $c cluster only has ${numMembers}/2 cluster members"
	fi
    else
        if [[ $numMembers -ne 3 ]]; then
            echo "--- ERROR --- $c cluster only has ${numMembers}/3 cluster members"
            failureMsg="${failureMsg}\nERROR: $c cluster only has ${numMembers}/3 cluster members"
        fi
    fi

    # Determine patroni version - remove carriage return without line feed.
    # Set a delay of 10 seconds for use with timeout command:
    Delay=10
    for member_i in $members
    do
        patronictlVersion=$(timeout -k 4 --preserve-status --foreground $Delay \
kubectl exec -it -n $c_ns -c postgres $member_i -- patronictl version | \
awk '{ sub("\r", "", $3); print $3 }'; )

        # Check response in case command hung or timed out.
        # If no response, check the next cluster member:
        if [[ -n $patronictlVersion ]]
        then
            break
        else
            continue
        fi
        done

	patronictlCmd=""
	case $patronictlVersion in
            "1.6.4" )
                patronictlCmd="\$(timeout -k 4 --preserve-status --foreground \
$Delay kubectl -n $c_ns -c postgres exec \$m -- patronictl list 2>/dev/null | awk ' \$8 == \
 \"Leader\" && \$10 == \"running\" {print \$4}')"
		getLagCmd="\$(kubectl -n $c_ns -c postgres exec \$leader -- patronictl list 2>/dev/null | grep running \
| grep -v Leader | awk '{print \$13 \" \" \$14}')"
		;;
            "1.6.5" )
                patronictlCmd="\$(timeout -k 4 --preserve-status --foreground \
$Delay kubectl -n $c_ns -c postgres exec \$m -- patronictl list 2>/dev/null | awk ' \$6 == \
\"Leader\" && \$8 == \"running\" {print \$2}')"
		getLagCmd="\$(kubectl -n $c_ns -c postgres exec \$leader -- patronictl list 2>/dev/null | grep running \
| grep -v Leader | awk '{print \$11 \" \" \$12}')"
		;;
            * )
                echo "Unexpected Patronictl version \"$patronictlVersion\" for \
the $c_name postgres clusters in the $c_ns namespace."
                echo
                echo $dottedLine
                echo $dottedLine
                echo
                continue
                ;;
        esac

	# Find the leader:
        podDescribe=" non-leader"
        for m in $members
        do
            eval leader="$patronictlCmd"
            if [ -n "$leader" ]
            then
                break;
            fi
        done
        if [ -z "$leader" ]
        then
	    failureMsg="${failureMsg}\nERROR: Unable to determine a leader for the $c_name cluster in \
$numMembers pods"
            podDescribe=""
            echo "=== ********************************************************\
************************** ==="
            echo "=== ****** Unable to determine a leader for the $c_name cluster in \
$numMembers pods ****** ==="
            echo "=== ********************************************************\
************************** ==="
            echo
            echo "--- Patronictl version: $patronictlVersion ---"
            echo
            kubectl get pods -A -o wide | grep "NAME\|$c_name"
            other=$members
        else
            # Have a leader:
            echo "=== Looking at patronictl list info for the $c_name cluster \
with leader pod: $leader ==="

            other="$(echo $members | xargs -n 1 | grep -v $leader)"

            echo; echo "--- patronictl, version $patronictlVersion, list for $c_ns \
leader pod $leader ---"
            kubectl -n $c_ns -c postgres exec $leader -- patronictl list 2>/dev/null

            # verify the state of each cluster member is 'running'
	    membersRunningPatroniFail=0
	    num_running_patronictl=$(kubectl -n $c_ns -c postgres exec $leader -- patronictl list 2>/dev/null | grep running | wc -l)
	    if [[ ! -z $(echo $leader | grep 'sma-postgres-cluster') ]]; then
                if [[ $num_running_patronictl -ne 2 ]]; then membersRunningPatroniFail=1; fi
            else
	         if [[ $num_running_patronictl -ne 3 ]]; then membersRunningPatroniFail=1; fi
	    fi
	    if [[ $membersRunningPatroniFail -eq 1 ]]; then
                echo "--- ERROR --- state of each $c_name member is not 'running'"
                failureMsg="${failureMsg}\nERROR: state of each $c_name member is not 'running'"
	    fi

	    # verify there is no large or growing Lag
            lagWarning=0
            eval lagValues="$getLagCmd"
	    for lag in $lagValues; do
	        if [[ $lag != '|' ]] && [[ $lag == 'unknown' || $lag -gt 0 ]]; then
	            echo "--- WARNING --- $c_name members have Lag"; echo
                    failureMsg="${failureMsg}\nWARNING: $c_name members have Lag. Lag does not always indicate \
there is a problem. Look below to see if prometheous alerts for this are firing."
                    lagWarning=1
                    lagFlag=1
		    break
                fi
	    done
	    kubectl get pods -A -o wide | grep "NAME\|$c_name"
	    # check that all pods are running
            num_running=$(kubectl get pods -A -o wide | grep $c_name | grep Running | grep -v pooler | wc -l)
	    has_pooler_pods=$(kubectl get pods -A -o wide | grep $c_name | grep pooler)
	    num_pooler_running=$(kubectl get pods -A -o wide | grep $c_name | grep Running | grep pooler | wc -l)
	    podsRunningFail=0
	    if [[ $c_name == "sma-postgres-cluster" ]]; then
	        if [[ $num_running -ne 2 ]]; then podsRunningFail=1; fi
	    else
	        if [[ $num_running -ne 3 ]]; then podsRunningFail=1; fi
	    fi
            if [[ ! -z $has_pooler_pods && $num_pooler_running -ne 3 ]]; then podsRunningFail=1; fi # 3 pooler pods is default value but this is configurable
	    if [[ $podsRunningFail -eq 1 ]]; then
                echo "--- ERROR --- not all $c_name pods have status 'Running'"
                failureMsg="${failureMsg}\nERROR: not all $c_name pods have status 'Running'"
	    fi
            if [[ $podsRunningFail -eq 1 || $lagWarning -eq 1 || $membersRunningPatroniFail -eq 1 ]]; then printErrorLogs; fi
        fi
        echo;
        echo $dottedLine
        echo $dottedLine
        echo
done
echo "=== kubectl get pods -A -o wide | grep \"NAME\|postgres-\" |\
 grep -v \"operator\|Completed\|pooler\" ==="
echo
kubectl get pods -A -o wide | grep "NAME\|postgres-" | grep -v "operator\|Completed\|pooler"

echo
if [[ -z $failureMsg ]]; then echo "PASSED. All postgresql checks passed."
else echo -e "--- FAILURE --- \n \n- Errors and Warnings are printed below - $failureMsg"; fi

if [[ $lagFlag -eq 1 ]]; then
    # look at prometheous alerts
    echo
    echo "**** Due to Lag being detected, Promtheous alerts will be checked to see if any Postgres Lag alerts are firing ****"
    echo " -- Analysis of output is needed to determine if lag is causing a problem --"
    echo " -- If nothing is printed below the alert title, then the Lag is likely not causing issues --"
    clusterIP=$(kubectl -n sysmgmt-health get svc cray-sysmgmt-health-promet-prometheus -o jsonpath='{.spec.clusterIP}')
    port=$(kubectl -n sysmgmt-health get svc cray-sysmgmt-health-promet-prometheus -o jsonpath='{.spec.ports[].port}')
    echo; echo "** Alert: PostgresqlReplicationLagSMA **"
    curl -s http://${clusterIP}:${port}/api/v1/alerts | jq . | grep -B 10 -A 20 PostgresqlReplicationLagSMA
    echo; echo "** Alert: PostgresqlReplicationLagServices **"
    curl -s http://${clusterIP}:${port}/api/v1/alerts | jq . | grep -B 10 -A 20 PostgresqlReplicationLagServices
    echo; echo "** Alert: PostgresqlFollowerReplicationLagSMA **"
    curl -s http://${clusterIP}:${port}/api/v1/alerts | jq . | grep -B 10 -A 20 PostgresqlFollowerReplicationLagSMA
    echo; echo "** Alert: PostgresqlFollowerReplicationLagServices **"
    curl -s http://${clusterIP}:${port}/api/v1/alerts | jq . | grep -B 10 -A 20 PostgresqlFollowerReplicationLagServices
fi

if [[ -z $failureMsg ]]; then exit 0; else exit 1; fi
