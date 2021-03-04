#!/bin/bash

# Copyright 2021 Hewlett Packard Enterprise Development LP
#
# The getXname script returns a list of NCN names, their associated xnames,
# and their metal.no-wipe setting.
#
# The script requires that the CLI command is enabled on the NCN node that
# it is executed on.
#

echo "             +++++ Get NCN Xnames +++++"
echo "=== Can be executed on any worker or master ncn node. ==="
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

echo
echo "=== NCN node xnames and metal.no-wipe status ==="
echo "=== metal.no-wipe=1, expected setting - the client ==="
echo "=== already has the right partitions and a bootable ROM. ==="
echo "=== Requires CLI to be initialized ==="
echo "=== NCN Master nodes: ${mNcnNodes}==="
echo "=== NCN Worker nodes: ${wNcnNodes}==="
echo "=== NCN Storage nodes: $sNcnNodes ==="
date; for ncn_i in $ncnNodes
      do
          echo -n "$ncn_i: "
          xName=$(ssh -q -o StrictHostKeyChecking=no $ncn_i 'cat /etc/cray/xname')
          if [[ -z $xName ]]
          then
              echo "Failed to obtain xname for $ncn_i"
              continue;
          fi
          if [[ $ncn_i == "ncn-m001" ]]
          then
              macAddress=$(cray bss bootscript list --name $xName | grep chain)
              macAddress=${macAddress#*mac=}
              macAddress=${macAddress%&arch*}
              noWipe=$(cray bss bootscript list --mac $macAddress --arch x86 \
                            | grep -o metal.no-wipe=[01])
          else
              noWipe=$(cray bss bootscript list --name $xName | \
                            grep -o metal.no-wipe=[01])
          fi
          echo "$xName - $noWipe"
      done
echo

exit 0
