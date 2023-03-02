#!/bin/bash
#
# Simple script to extract software versions from configmap
#

kubectl get cm -n services cray-product-catalog -o json | jq -r .data.csm
