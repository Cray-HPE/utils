#!/usr/bin/env python3

import os
import sys
import yaml

file_name=sys.argv[1]
file_name = '/root/etcd/' + file_name + '.yaml'
with open(file_name) as f:
    y=yaml.safe_load(f)

    del  y['metadata']['creationTimestamp']
    del  y['metadata']['generation']
    del  y['metadata']['resourceVersion']
    del  y['metadata']['uid']
    del  y['status']

with open(file_name, 'w') as outputFile:
    yaml.dump(y,outputFile, default_flow_style=False, sort_keys=False)

