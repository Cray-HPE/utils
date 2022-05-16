#!/bin/bash
#
# MIT License
#
# (C) Copyright 2021-2022 Hewlett Packard Enterprise Development LP
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

#shellcheck disable=SC2155
export TOKEN=$(get_token)
if [[ -z $TOKEN ]]
then
    echo "Failed to get token, skipping metal.no-wipe checks."
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
            #shellcheck disable=SC2062
            noWipe=$(curl -s -k -H "Authorization: Bearer ${TOKEN}" "https://api-gw-service-nmn.local/apis/bss/boot/v1/bootscript?mac=${macAddress}&arch=x86" | grep -o metal.no-wipe=[01])
        else
            #shellcheck disable=SC2062
            noWipe=$(curl -s -k -H "Authorization: Bearer ${TOKEN}" "https://api-gw-service-nmn.local/apis/bss/boot/v1/bootscript?name=${xName}" | grep -o metal.no-wipe=[01])
        fi
        if [[ -z $noWipe ]]; then sleep 3; fi
        iter=$(($iter + 1))
    done
    if [[ -z $noWipe ]]; then noWipe='unavailable'; fi
    echo "$xName - $noWipe"
done
echo

exit 0

