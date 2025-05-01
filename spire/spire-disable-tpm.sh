#!/bin/bash
#
# MIT License
#
# (C) Copyright 2025 Hewlett Packard Enterprise Development LP
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
		echo "cray-spire-server did not start after $(("$RETRY_SECONDS" * "$MAX_RETRIES" )) seconds."
		exit 1
	fi
	sleep "$RETRY_SECONDS"
done

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

kubectl rollout restart -n spire DaemonSet/request-ncn-join-token
kubectl rollout status -n spire DaemonSet/request-ncn-join-token
all_nodes="$(kubectl get nodes -ojsonpath='{.items[*].metadata.name}') $(ceph node ls | jq -r '.[] | keys[]' | sort -u)"
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
KEYSJSON="${DATADIR}/keys.json"
BUNDLEDER="${PREFIX}/bundle.der"
AGENTSVIDDER="${PREFIX}/agent_svid.der"
SPIREAGENT="${CONF}/spire-agent.conf"
SPIREBUNDLE="${CONF}/bundle.crt"
TPMPROVISIONER="/opt/cray/cray-spire/tpm-provisioner-client"

for node in $tpm_nodes; do
	if sshnh "$node" test -f /var/lib/spire/conf/tpm.enabled; then
		echo "$node is joined to spire with tpm, disabling now"
                sshnh "$node" systemctl stop spire-agent.service
                sshnh "$node" rm "${KEYSJSON}" "${SVIDKEY}" "${BUNDLEDER}" "${AGENTSVIDDER}" "${SPIREAGENT}" || true
		sshnh "$node" systemctl start spire-agent
		sshnh "$node" rm /var/lib/spire/conf/tpm.enabled
	fi
done
