#!/usr/bin/python3

# MIT License
#
# (C) Copyright [2020-2021] Hewlett Packard Enterprise Development LP
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


import sys
import csv
import requests

"""
This python script used to capture memory usage, CPU usage, and network bandwidth metrics 
for critical boot services  result of a Prometheus query as CSV.
"""
def query_response_results(prom_url,metrics):
    # prom_url could be an IP address or prometheus url
    # metrics which prometheus metrics to query
  return requests.get('{0}/api/v1/query'.format(prom_url),
            params={'query': metrics}).json()['data']['result']

def metric_query(metrics,index,service):
    # returns prometheus metrics with specific boot service
  return metrics[:index] + service + metrics[index:]

cstr = "STARTING"
print (cstr.center(80, '$'))
if len(sys.argv) != 4:
    print('Use the time in prometheus format example 30s or 10m or 5h')
    print('Script Usage: {0} http://prometheus:9090 50m csv-filename.csv '.format(sys.argv[0]))
    print('Refer csv-filename.csv output file')
    sys.exit(1)
prometheus_url = sys.argv[1]
otime = sys.argv[2]
csvfilename = sys.argv[3]
"""
Add service name to services want to check Service Resource Consumption
"""
services = ['cray-smd', 'cray-bss', 'cray-capmc', 'cray-hbtd', 'cray-cps', 'slurm']
m_metrics = 'sum(container_memory_usage_bytes{pod=~".*.*"})'
c_metrics = 'sum(rate(container_cpu_usage_seconds_total{pod=~".*.*"}[%s]))' % otime
r_metrics = 'sum(rate(container_network_receive_bytes_total{pod=~".*.*"}[%s]))' % otime
t_metrics = 'sum(rate(container_network_transmit_bytes_total{pod=~".*.*"}[%s]))' % otime
memory_index = m_metrics.find('.*"')
cpu_index = c_metrics.find('.*"')
receive_index = r_metrics.find('.*"')
transmit_index = t_metrics.find('.*"')

with open(csvfilename, mode='w') as critical_resource:
    writer = csv.writer(critical_resource)
    # Write the header,
    writer.writerow(['', 'SERVICE NAME', 'TIMESTAMP ', 'MEMORY USAGE', 'CPU USAGE', 'NETWORK RECEIVE BYTES', 'NETWORK TRANSMIT BYTES'])
    for service in services:
        memory_metrics = m_metrics[:memory_index] + service + m_metrics[memory_index:]
        memory_metrics = metric_query(m_metrics,memory_index,service)
        cpu_metrics = metric_query(c_metrics,cpu_index,service)
        receive_metrics =  metric_query(r_metrics,receive_index,service)
        transmit_metrics = metric_query(t_metrics,transmit_index,service)
        memory_results = query_response_results(prometheus_url,memory_metrics)
        cpu_results = query_response_results(prometheus_url,cpu_metrics)
        receive_results = query_response_results(prometheus_url,receive_metrics)
        transmit_results = query_response_results(prometheus_url,transmit_metrics)
        if memory_results and cpu_results and receive_results and transmit_results:
            service_row = [memory_results[0]['metric'].get('__name__', '')] + memory_results[0]['value']
            service_row.insert(1,service)
            service_row.insert(4,cpu_results[0]['value'][1])
            service_row.insert(5,receive_results[0]['value'][1])
            service_row.insert(6,transmit_results[0]['value'][1])
            writer.writerow(service_row)
cstr = "  Collected the Boot Critical Service Resource Consumption  "
print (cstr.center(80, '$'))
cstr = "  Please Refer %s output file  "  % csvfilename
print (cstr.center(80, '$'))
cstr = "DONE"
print (cstr.center(80, '$'))
