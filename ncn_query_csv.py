#!/usr/bin/python3
# -*- coding: utf-8 -*-

import csv
import requests
import sys
import getopt
import time
import logging
from datetime import datetime


PROMETHEUS_URL = ''
CONTAINER = ''
QUERY_API = '/api/v1/query'
RANGE_QUERY_API = '/api/v1/query_range'
RESOLUTION = '' # default: 10s
OUTPUTFILE = '' # default: result.csv
START = '' # rfc3339 | unix_timestamp
END = '' # rfc3339 | unix_timestamp
PERIOD = 60 # unit: minute, default 60

def main():
    handle_args(sys.argv[1:])

    metricnames, metricnames_desc = query_metric_names()
    #print(metricnames)
    #print(metricnames_desc)
    logging.info("Querying metric names succeeded, metric number: %s", len(metricnames))

    csvset = query_metric_values(metricnames=metricnames)
    logging.info("Querying metric values succeeded, rows of data: %s", len(csvset))

    write2csv(filename=OUTPUTFILE, metricnames=metricnames_desc, dataset=csvset)

def handle_args(argv):
    global PROMETHEUS_URL
    global OUTPUTFILE
    global CONTAINER
    global RESOLUTION
    global START
    global END
    global PERIOD

    try:
        opts, args = getopt.getopt(argv, "h:o:c:s:", ["host=", "outfile=", "step=", "help", "start=", "end=", "period="])
    except getopt.GetoptError as error:
        logging.error(error)
        print_help_info()
        sys.exit(2)

    for opt, arg in opts:
        if opt == "--help":
            print_help_info()
            sys.exit()
        elif opt in ("-h", "--host"):
            PROMETHEUS_URL = arg
        elif opt in ("-o", "--outfile"):
            OUTPUTFILE = arg
        elif opt in ("-s", "--step"):
            RESOLUTION = arg
        elif opt == "--start":
            START = arg
        elif opt == "--end":
            END = arg
        elif opt == "--period":
            PERIOD = int(arg)

    if PROMETHEUS_URL == '':
        logging.error("You should use -h or --host to specify your prometheus server's url, e.g. http://prometheus:9090")
        print_help_info()
        sys.exit(2)

    if OUTPUTFILE == '':
        OUTPUTFILE = 'result.csv'
        logging.warning("You didn't specify output file's name, will use default name %s", OUTPUTFILE)
    if RESOLUTION == '':
        RESOLUTION = '10s'
        logging.warning("You didn't specify query resolution step width, will use default value %s", RESOLUTION)
    if PERIOD == '' and START == '' and END == '':
        PERIOD = 10
        logging.warning("You didn't specify query period or start&end time, will query the latest %s miniutes' data as a test", PERIOD)

def print_help_info():
    print('')
    print('Metrics2CSV Help Info')
    print('    metrics2csv.py -h <prometheus_url> -c <container_name> [-o <outputfile>]')
    print('or: metrics2csv.py --host=<prometheus_url> --container=<container_name> [--outfile=<outputfile>]')
    print('---')
    print('Additional options: --start=<start_timestamp_or_rfc3339> --end=<end_timestamp_or_rfc3339> --period=<get_for_most_recent_period(int miniutes)>')
    print('                    use start&end or only use period')

def metric_query(metrics,index,service):
    # returns prometheus metrics with specific boot service
    return metrics[:index] + service + metrics[index:]

def query_metric_names():
    metricnames = list()
    metricnames_desc = list()

    #NCN NODE METRICS
    #MEMORY

    ncn_memory_free = 'node_memory_MemFree_bytes{job="node-exporter", instance="NCN"}'
    ncn_memory_buffers = 'node_memory_Buffers_bytes{job="node-exporter", instance="NCN"}'
    ncn_memory_cache = 'node_memory_Cached_bytes{job="node-exporter", instance="NCN"}'
    ncn_memory_used = 'node_memory_MemTotal_bytes{job="node-exporter", instance="NCN"}'
   
    #CPU
    ncn_cpu = 'sum(((  (1 - rate(node_cpu_seconds_total{job="node-exporter", mode="idle", instance="NCN"}[1m]))/ ignoring(cpu) group_left  count without (cpu)( node_cpu_seconds_total{job="node-exporter", mode="idle", instance="NCN"}))))'
    
    #NETWORK
  
    ncn_network_received = 'sum(rate(node_network_receive_bytes_total{job="node-exporter", instance="NCN", device!="lo"}[1m]))'
    ncn_network_transmitted = 'sum(rate(node_network_transmit_bytes_total{job="node-exporter", instance="NCN", device!="lo"}[1m]))'


    #NCN NODE METRICS DESCRIPTIONS
    
    #MEMORY
    ncn_memory_buffers_name = 'NCN node memory buffers bytes'
    ncn_memory_free_name = 'NCN node memory free bytes'
    ncn_memory_cache_name = 'NCN node memory cache bytes'
    ncn_memory_used_name = 'NCN node memory used bytes'

    #CPU
    ncn_cpu_name = 'NCN node cpu usage'

    #NETWORK

    ncn_network_received_name = 'NCN node network receive bytes'
    ncn_network_transmitted_name = 'NCN node network transmitted bytes'

    response = requests.get(PROMETHEUS_URL + QUERY_API, params={'query': 'node_exporter_build_info{job="node-exporter"}'})
    status = response.json()['status']

    if status == "error":
        logging.error(response.json())
        sys.exit(2)
    
    results = response.json()['data']['result']
    metricnames = list()
    for result in results:
        #print(result['metric'].get('instance', ''))
        #metricnames.append(ncn_memory_buffers.format(result['metric'].get('instance', '')))
        node = result['metric'].get('instance', '')
        #MEMORY
        ncn_memory_buffers_metrics = ncn_memory_buffers.replace("NCN", node)
        ncn_memory_buffers_metrics_name = ncn_memory_buffers_name.replace("NCN", node)
        metricnames.append(ncn_memory_buffers_metrics)
        metricnames_desc.append(ncn_memory_buffers_metrics_name)

        
        ncn_memory_free_metrics = ncn_memory_free.replace("NCN", node)
        ncn_memory_free_metrics_name = ncn_memory_free_name.replace("NCN", node)
        metricnames.append(ncn_memory_free_metrics)
        metricnames_desc.append(ncn_memory_free_metrics_name)      

        ncn_memory_cache_metrics = ncn_memory_cache.replace("NCN", node)
        ncn_memory_cache_metrics_name = ncn_memory_cache_name.replace("NCN", node)
        metricnames.append(ncn_memory_cache_metrics)
        metricnames_desc.append(ncn_memory_cache_metrics_name)
        
        ncn_memory_used_metrics = ncn_memory_used.replace("NCN", node)
        ncn_memory_used_metrics_name = ncn_memory_used_name.replace("NCN", node)
        metricnames.append(ncn_memory_used_metrics)
        metricnames_desc.append(ncn_memory_used_metrics_name)

        #CPU
        ncn_cpu_metrics = ncn_cpu.replace("NCN", node, 2)
        ncn_cpu_metrics_name = ncn_cpu_name.replace("NCN", node)
        metricnames.append(ncn_cpu_metrics)
        metricnames_desc.append(ncn_cpu_metrics_name)

        #NETWORK

        ncn_network_received_metrics = ncn_network_received.replace("NCN", node)
        ncn_network_received_metrics_name = ncn_network_received_name.replace("NCN", node)
        metricnames.append(ncn_network_received_metrics)
        metricnames_desc.append(ncn_network_received_metrics_name)

        ncn_network_transmitted_metrics = ncn_network_transmitted.replace("NCN", node)
        ncn_network_transmitted_metrics_name = ncn_network_transmitted_name.replace("NCN", node)
        metricnames.append(ncn_network_transmitted_metrics)
        metricnames_desc.append(ncn_network_transmitted_metrics_name)

    return metricnames, metricnames_desc;


def query_metric_values(metricnames):
    csvset = dict()
    
    if PERIOD != '':
        end_time = int(time.time())
        start_time = end_time - 60 * PERIOD
    else:
        end_time = END
        start_time = START

    metric = metricnames[0]
    #print(metric)
    response = requests.get(PROMETHEUS_URL + RANGE_QUERY_API, params={'query': '{0}'.format(metric), 'start': start_time, 'end': end_time, 'step': RESOLUTION})
    status = response.json()['status']
    if status == "error":
        logging.error(response.json())
        sys.exit(2)

    results = response.json()['data']['result']
    if len(results) == 0:
        logging.error(response.json())
        sys.exit(2)

    for value in results[0]['values']:
        csvset[value[0]] = [value[1]]

    for metric in metricnames[1:]:
        #print(metric)
        response = requests.get(PROMETHEUS_URL + RANGE_QUERY_API, params={'query': '{0}'.format(metric), 'start': start_time, 'end': end_time, 'step': RESOLUTION})
        #print(response.status_code)
        results = response.json()['data']['result']
        for value in results[0]['values']:
             csvset[value[0]].append(value[1])
    return csvset

def write2csv(filename, metricnames, dataset):
    with open(filename, 'w') as file:
        writer = csv.writer(file)
        writer.writerow(['timestamp'] + metricnames)
        for timestamp in sorted(dataset.keys(), reverse=True):
            #unix_val = datetime.fromtimestamp(timestamp).strftime("%Y-%m-%d %H:%M:%S")
            unix_val = datetime.fromtimestamp(timestamp)
            writer.writerow([unix_val] + dataset[timestamp])
        # for line in dataset:
        #     writer.writerow([line] + dataset[line])

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    main()

