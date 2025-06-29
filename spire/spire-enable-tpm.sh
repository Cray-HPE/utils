#!/bin/bash
#
# MIT License
#
# (C) Copyright 2023 Hewlett Packard Enterprise Development LP
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
set -euo pipefail

RETRY=0
MAX_RETRIES=30
RETRY_SECONDS=10

until kubectl exec -itn spire cray-spire-server-0 --container spire-server -- ./bin/spire-server healthcheck | grep -q 'Server is healthy'; do
	if [[ "$RETRY" -lt "$MAX_RETRIES" ]]; then
		RETRY="$((RETRY + 1))"
		echo "cray-spire-server is not ready. Will retry after $RETRY_SECONDS seconds. ($RETRY/$MAX_RETRIES)"
	else
		echo "cray-spire-server did not start after $(echo "$RETRY_SECONDS" \* "$MAX_RETRIES" | bc) seconds."
		exit 1
	fi
	sleep "$RETRY_SECONDS"
done

URL="https://cray-spire-tokens.spire:54440/api/token"
API_GATEWAY="https://api-gw-service-nmn.local"
client_secret=$(kubectl get secrets admin-client-auth -ojsonpath='{.data.client-secret}' | base64 -d)
KC_TOKEN=$(curl -s -d grant_type=client_credentials \
        -d client_id=admin-client \
        --data-urlencode client_secret=${client_secret} \
        ${API_GATEWAY}/keycloak/realms/shasta/protocol/openid-connect/token | jq -r '.access_token')
POD=$(kubectl get pods -n spire | grep cray-spire-server | grep Running | awk 'NR==1{print $1}')
LOADBALANCERIP=$(kubectl get service -n spire cray-spire-cluster --no-headers --output=jsonpath='{.spec.loadBalancerIP}')

function sshnh() {
	/usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
}
function scpnh() {
	/usr/bin/scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
}

if hostname | grep -q 'pit'; then
	echo "This script is not supported on pit nodes. Please run it on ncn-m002."
	exit 1
fi

all_nodes="$(kubectl get nodes -o name | cut -d"/" -f2) $(ceph node ls | jq -r '.[] | keys[]' | sort -u)"
tpm_nodes=""
for node in $all_nodes; do
	if ssh "$node" test -c /dev/tpm0; then
		tpm_nodes="${tpm_nodes} $node";
	fi
done

# Make changes to the installation prefix a bit easier with vars
PREFIX=/var/lib/spire
CONF="${PREFIX}/conf"
SOCKET="${PREFIX}/agent.sock"
DATADIR="${PREFIX}/data"
SVIDKEY="${DATADIR}/svid.key"
BUNDLEDER="${PREFIX}/bundle.der"
AGENTSVIDDER="${PREFIX}/agent_svid.der"
SPIREAGENT="${CONF}/spire-agent.conf"
SPIREBUNDLE="${CONF}/bundle.crt"
TPMPROVISIONER="/opt/cray/cray-spire/tpm-provisioner-client"

for node in $tpm_nodes; do
	if sshnh "$node" test -f /var/lib/spire/conf/tpm.enabled; then
		echo "$node is already joined to spire with tpm."
	else
		XNAME=$(sshnh "$node" cat /etc/cray/xname)

		curl -H "Authorization: Bearer $KC_TOKEN" -d "xname=$XNAME" $API_GATEWAY:/apis/tpm-provisioner/whitelist/add
		sshnh "$node" ${TPMPROVISIONER}
		sshnh "$node" systemctl stop spire-agent.service

		if sshnh "$node" ls "${SVIDKEY}" >/dev/null 2>&1; then
			echo "$node was once joined to spire. Cleaning up old files"
			sshnh "$node" rm "${SVIDKEY}" "${BUNDLEDER}" "${AGENTSVIDDER}" || true
		fi
		echo "$node is being joined to spire."
		cat << EOF > /tmp/spire-tpm-conf.conf
agent {
  data_dir = "$PREFIX"
  log_level = "INFO"
  server_address = "$LOADBALANCERIP"
  server_port = "8081"
  socket_path = "$SOCKET"
  trust_bundle_path = "$SPIREBUNDLE"
  trust_domain = "shasta"
}

plugins {
  NodeAttestor "tpm_devid" {
        plugin_data {
            devid_cert_path = "/var/lib/tpm-provisioner/devid.crt.pem"
            devid_priv_path = "/var/lib/tpm-provisioner/devid.priv.blob"
            devid_pub_path = "/var/lib/tpm-provisioner/devid.pub.blob"
        }
    }

  KeyManager "disk" {
    plugin_data {
        directory = "$DATADIR"
    }
  }

  WorkloadAttestor "unix" {
    plugin_data {
        discover_workload_path = true
    }
  }
}
EOF
		scpnh /tmp/spire-tpm-conf.conf "$node":${SPIREAGENT}
		sshnh "$node" systemctl start spire-agent
		sshnh "$node" touch /var/lib/spire/conf/tpm.enabled
	fi
done
