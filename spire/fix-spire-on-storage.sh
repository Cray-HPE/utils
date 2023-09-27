#!/bin/bash
#
# MIT License
#
# (C) Copyright 2022 Hewlett Packard Enterprise Development LP
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
POD=$(kubectl get pods -n spire | grep cray-spire-server | grep Running | awk 'NR==1{print $1}')
LOADBALANCERIP=$(kubectl get service -n spire cray-spire-local --no-headers --output=jsonpath='{.spec.loadBalancerIP}')

RETRY=0
until [[ ! -z $POD && ! -z $LOADBALANCERIP ]]; do
	if [[ "$RETRY" -lt "$MAX_RETRIES" ]]; then
		RETRY="$((RETRY + 1))"
		echo "Either POD or LOADBALANCERIP was not set. Will retry after $RETRY_SECONDS seconds. ($RETRY/$MAX_RETRIES)"
	else
		if [[ -z $POD ]]; then
			echo "No cray-spire-server pod is running after $(echo "$RETRY_SECONDS" \* "$MAX_RETRIES" | bc) seconds."
		fi
		if [[ -z $LOADBALANCERIP ]]; then
			echo "cray-spire-local service is not ready after $(echo "$RETRY_SECONDS" \* "$MAX_RETRIES" | bc) seconds."
		fi
		exit 1
	fi
	sleep "$RETRY_SECONDS"
	POD=$(kubectl get pods -n spire | grep cray-spire-server | grep Running | awk 'NR==1{print $1}')
	LOADBALANCERIP=$(kubectl get service -n spire cray-spire-local --no-headers --output=jsonpath='{.spec.loadBalancerIP}')
done

function sshnh() {
	/usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
}

if hostname | grep -q 'pit'; then
	echo "This script is not supported on pit nodes. Please run it on ncn-m002."
	exit 1
fi

set -euo pipefail

nodes=$(ceph node ls | jq -r '.[] | keys[]' | sort -u)

# Make changes to the installation prefix a bit easier with vars
prefix=/var/lib/spire
conf="${prefix}/conf"
socket="${prefix}/agent.sock"
datadir="${prefix}/data"
svidkey="${datadir}/svid.key"
bundleder="${prefix}/bundle.der"
agentsvidder="${prefix}/agent_svid.der"
jointoken="${conf}/join_token"
spireagent="${conf}/spire-agent.conf"
spirebundle="${conf}/bundle.crt"

for node in $nodes; do
	if sshnh "$node" spire-agent healthcheck -socketPath="${socket}" 2>&1 | grep -q "healthy"; then
		echo "$node is already joined to spire and is healthy."
	else
		if sshnh "$node" ls "${svidkey}" >/dev/null 2>&1; then
			echo "$node was once joined to spire. Cleaning up old files"
			sshnh "$node" rm "${svidkey}" "${bundleder}" "${agentsvidder}" || true
		fi
		echo "$node is being joined to spire."
		XNAME="$(sshnh "$node" cat /proc/cmdline | sed 's/.*xname=\([A-Za-z0-9]*\).*/\1/')"
		TOKEN="$(kubectl exec -n spire "$POD" --container registration-server -- curl -k -X POST -d type=storage\&xname="$XNAME" "$URL" | tr ':' '=' | tr -d '"{}')"
		sshnh "$node" "echo $TOKEN > ${jointoken}"
		kubectl get configmap -n spire cray-spire-ncn-config -o jsonpath='{.data.spire-agent\.conf}' | sed "s/server_address.*/server_address = \"$LOADBALANCERIP\"/" | sshnh "$node" "cat > ${spireagent}"
		kubectl get configmap -n spire cray-spire-bundle -o jsonpath='{.data.bundle\.crt}' | sshnh "$node" "cat > ${spirebundle}"
		sshnh "$node" systemctl enable spire-agent
		sshnh "$node" systemctl start spire-agent
	fi
done
