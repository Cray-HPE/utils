#!/bin/bash

# Copyright 2021-2023 Hewlett Packard Enterprise Development LP
#
# The ncnGetXnames script returns a list of NCN names, the associated xname
# and metal.no-wipe setting.
#
# Returned results are not verified. Information is provided to aide in
# analysis of the results.
#
# The ncnGetXnames script can be run on any worker or master NCN node from
# any directory. The ncnHealthChecks script can be run before and after an
# NCN node is rebooted.
#

# Set a delay of 15 seconds for use with ssh timeout option:
Delay=${Delay:-15}
sshOptions="-q -o StrictHostKeyChecking=no -o ConnectTimeout=$Delay"

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

echo "             +++++ Get NCN Xnames +++++"
echo "=== Can be executed on any worker or master NCN node. ==="
hostName=$(hostname)
echo "=== Executing on $hostName, $(date) ==="

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

ncnNodes=${mNcnNodes}${wNcnNodes}$sNcnNodes
echo "NCN nodes: $ncnNodes"

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
    exit_code=1
elif [[ $noWipeFail -eq 2 ]]
then
    echo " --- FAILED --- Failed to get token, skipped metal.no-wipe checks. Could not verify no-wipe status.";
    exit_code=1
else echo " --- PASSED ---"; fi
echo

exit $exit_code


