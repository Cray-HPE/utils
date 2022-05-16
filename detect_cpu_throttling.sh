#!/bin/sh
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
# Usage: detect_cpu_throttling.sh [pod_name_substr] (default evaluates all pods)
#

str=$1
: ${str:=.}

#shellcheck disable=SC3011
while read ns pod node; do
  echo ""
  echo "Checking $pod"
  while read -r container; do
    uid=$(echo $container | awk 'BEGIN { FS = "/" } ; {print $NF}')
    #shellcheck disable=SC2087
    ssh -T ${node} <<-EOF
        dir=\$(find /sys/fs/cgroup/cpu,cpuacct/kubepods/burstable -name \*${uid}\* 2>/dev/null)
        [ "\${dir}" = "" ] && { dir=\$(find /sys/fs/cgroup/cpu,cpuacct/system.slice/containerd.service -name \*${uid}\* 2>/dev/null); }
        if [ "\${dir}" != "" ]; then
          num_periods=\$(grep nr_throttled \${dir}/cpu.stat | awk '{print \$NF}')
          if [ \${num_periods} -gt 0 ]; then
            echo "*** CPU throttling for containerid ${uid}: ***"
            cat \${dir}/cpu.stat
            echo ""
          fi
        fi
	EOF

  done <<< "`kubectl -n $ns get pod $pod -o yaml | grep ' - containerID'`"
done <<<"$(kubectl get pods -A -o wide | grep $str | grep Running | awk '{print $1 " " $2 " " $8}')"
