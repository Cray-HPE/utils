#!/usr/bin/python3
# -*- coding: utf-8 -*-

import csv
import requests
import sys
import getopt
import time
import logging
from datetime import datetime

#ADD SERVICES BELOW FORMET TO MONITOR
services = ['cray-smd', 'cray-bss', 'cray-capmc', 'cray-hbtd', 'cray-cps', 'slurm']
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
    #services = ['cray-smd']
    #services = ['cray-smd', 'cray-bss', 'cray-capmc', 'cray-hbtd', 'cray-cps', 'slurm']
    #MEMORY METRICS
    m_metrics = 'sum(container_memory_working_set_bytes{pod=~".*.*"})'
    mreq_metrics = 'sum(kube_pod_container_resource_requests_memory_bytes{pod=~".*.*"})'
    mreq_percentage_metrics = 'sum(container_memory_working_set_bytes{pod=~".*.*"})/ sum(kube_pod_container_resource_requests_memory_bytes{pod=~".*.*"}) * 100'
    mlimit_metrics = 'sum(kube_pod_container_resource_limits_memory_bytes{pod=~".*.*"})'
    mlimit_percentage_metrics = 'sum(container_memory_working_set_bytes{pod=~".*.*"}) / sum(kube_pod_container_resource_limits_memory_bytes{pod=~".*.*"}) * 100'
    mrss_metrics = 'sum(container_memory_rss{pod=~".*.*"})'
    mcache_metrics = 'sum(container_memory_cache{pod=~".*.*"})'
    mswap_metrics = 'sum(container_memory_swap{pod=~".*.*"})'

    #CPU METRICS
 
    cpu_usage_metrics = 'sum(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate{pod=~".*.*"})'
    cpu_req_metrics = 'sum(kube_pod_container_resource_requests_cpu_cores{pod=~".*.*"})'
    cpu_reqp_metrics = 'sum(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate{pod=~".*.*"})  / sum(kube_pod_container_resource_requests_cpu_cores{pod=~".*.*"}) * 100'
    cpu_core_metrics = 'sum(kube_pod_container_resource_limits_cpu_cores{pod=~".*.*"})'
    cpu_corep_metrics = 'sum(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate{pod=~".*.*"}) / sum(kube_pod_container_resource_limits_cpu_cores{pod=~".*.*"})'

    #NETWORK METRICS

    nrb_metrics = 'sum(rate(container_network_receive_bytes_total{pod=~".*.*"}[1m]))'
    ntb_metrics = 'sum(rate(container_network_transmit_bytes_total{pod=~".*.*"}[1m]))'
    nrp_metrics = 'sum(rate(container_network_receive_packets_total{pod=~".*.*"}[1m]))'
    ntp_metrics = 'sum(rate(container_network_transmit_packets_total{pod=~".*.*"}[1m]))'
    nrpd_metrics = 'sum(rate(container_network_receive_packets_dropped_total{pod=~".*.*"}[1m]))'
    ntpd_metrics = 'sum(rate(container_network_transmit_packets_dropped_total{pod=~".*.*"}[1m]))'

    #MEMORY METRICS description
    mreq_metric_name = '-memory request bytes'
    memory_metric_name = '-memory usage bytes'
    mreq_percentage_metric_name = '-memory request %'
    mlimit_metric_name = '-memory limits'
    mlimit_percentage_metric_name = '-memory limits %'
    mrss_metric_name = '-memory usage(RSS)'
    mcache_metric_name = '-memory usage(cache)'
    mswap_metric_name = '-memory usage(swap)'

    #CPU METRICS description
    cpu_usage_metric_name = '-cpu usage'
    cpu_req_metric_name = '-cpu requests'
    cpu_reqp_metric_name = '-cpu requests %'
    cpu_core_metric_name = '-cpu limits'
    cpu_corep_metric_name = '-cpu limits %'


    #NETWORK METRICS description

    nrb_metric_name = '-total network recive bytes'
    ntb_metric_name = '-total network transmit bytes'
    nrp_metric_name = '-total network recive packets'
    ntp_metric_name = '-total network transmit packets'
    nrpd_metric_name = '-total recive packets dropped'
    ntpd_metric_name = '-total tramist packets dropped'


    #MEMORY INDEX
    memory_index = m_metrics.find('.*"')
    memory_index_name = memory_metric_name.find('-')

    mreq_index = mreq_metrics.find('.*"')
    mreq_index_name = mreq_metric_name.find('-')

    mreq_percentage_index = mreq_percentage_metrics.find('.*"')
    mreq_percentage_index_name = mreq_percentage_metric_name.find('-')

    mlimit_index = mlimit_metrics.find('.*"')
    mlimit_index_name = mlimit_metric_name.find('-')

    mlimit_percentage_index = mlimit_percentage_metrics.find('.*"')
    mlimit_percentage_index_name = mlimit_percentage_metric_name.find('-')
    
    mrss_index = mrss_metrics.find('.*"')
    mrss_index_name = mrss_metric_name.find('-')

    mcache_index = mcache_metrics.find('.*"')
    mcache_index_name = mcache_metric_name.find('-')

    mswap_index = mswap_metrics.find('.*"')
    mswap_index_name = mswap_metric_name.find('-')

    #CPU INDEX
    cpu_usage_index = cpu_usage_metrics.find('.*"')
    cpu_usage_index_name = cpu_usage_metric_name.find('-')

    cpu_req_index = cpu_req_metrics.find('.*"')
    cpu_req_index_name = cpu_req_metric_name.find('-')

    cpu_reqp_index = cpu_reqp_metrics.find('.*"')
    cpu_reqp_index_name = cpu_reqp_metric_name.find('-')

    cpu_core_index = cpu_core_metrics.find('.*"')
    cpu_core_index_name = cpu_core_metric_name.find('-')

    cpu_corep_index = cpu_corep_metrics.find('.*"')
    cpu_corep_index_name = cpu_corep_metric_name.find('-')

    #NETWORK INDEX

    nrb_index = nrb_metrics.find('.*"')
    nrb_index_name = nrb_metric_name.find('-')

    ntb_index = ntb_metrics.find('.*"')
    ntb_index_name = ntb_metric_name.find('-')

    nrp_index = nrp_metrics.find('.*"')
    nrp_index_name = nrp_metric_name.find('-')
  
    ntp_index = ntp_metrics.find('.*"')
    ntp_index_name = ntp_metric_name.find('-')

    nrpd_index = nrpd_metrics.find('.*"')
    nrpd_index_name = nrpd_metric_name.find('-')

    ntpd_index = ntpd_metrics.find('.*"')
    ntpd_index_name = ntpd_metric_name.find('-')


    for service in services:
        #MEMORY METRICS STATS
        memory_query_metrics = metric_query(m_metrics,memory_index,service)
        memory_query_metrics_name = metric_query(memory_metric_name,memory_index_name,service)
        metricnames.append(memory_query_metrics)
        metricnames_desc.append(memory_query_metrics_name)

        mreq_query_metrics = metric_query(mreq_metrics,mreq_index,service)
        mreq_query_metrics_name = metric_query(mreq_metric_name,mreq_index_name,service)
        metricnames.append(mreq_query_metrics)
        metricnames_desc.append(mreq_query_metrics_name)

        mreq_percentage_query_metrics = metric_query(mreq_percentage_metrics,mreq_percentage_index,service)
        mreq_percentage_query_metrics_name = metric_query(mreq_percentage_metric_name,mreq_percentage_index_name,service)
        metricnames.append(mreq_percentage_query_metrics)
        metricnames_desc.append(mreq_percentage_query_metrics_name)

        mlimit_query_metrics = metric_query(mlimit_metrics,mlimit_index,service)
        mlimit_query_metrics_name = metric_query(mlimit_metric_name,mlimit_index_name,service)
        metricnames.append(mlimit_query_metrics)
        metricnames_desc.append(mlimit_query_metrics_name)

        mlimit_percentage_query_metrics = metric_query(mlimit_percentage_metrics,mlimit_percentage_index,service)
        mlimit_percentage_query_metrics_name = metric_query(mlimit_percentage_metric_name,mlimit_percentage_index_name,service)
        metricnames.append(mlimit_percentage_query_metrics)
        metricnames_desc.append(mlimit_percentage_query_metrics_name)

        mrss_query_metrics = metric_query(mrss_metrics,mrss_index,service)
        mrss_query_metrics_name = metric_query(mrss_metric_name,mrss_index_name,service)
        metricnames.append(mrss_query_metrics)
        metricnames_desc.append(mrss_query_metrics_name)
    
        mcache_query_metrics = metric_query(mcache_metrics,mcache_index,service)
        mcache_query_metrics_name = metric_query(mcache_metric_name,mcache_index_name,service)
        metricnames.append(mcache_query_metrics)
        metricnames_desc.append(mcache_query_metrics_name)

        mswap_query_metrics = metric_query(mswap_metrics,mswap_index,service)
        mswap_query_metrics_name = metric_query(mswap_metric_name,mswap_index_name,service)
        metricnames.append(mswap_query_metrics)
        metricnames_desc.append(mswap_query_metrics_name)


        #CPU METRICS STATS
        cpu_usage_query_metrics = metric_query(cpu_usage_metrics,cpu_usage_index,service)
        cpu_usage_query_metrics_name = metric_query(cpu_usage_metric_name,cpu_usage_index_name,service)
        metricnames.append(cpu_usage_query_metrics)
        metricnames_desc.append(cpu_usage_query_metrics_name)

        cpu_req_query_metrics = metric_query(cpu_req_metrics,cpu_req_index,service)
        cpu_req_query_metrics_name = metric_query(cpu_req_metric_name,cpu_req_index_name,service)
        metricnames.append(cpu_req_query_metrics)
        metricnames_desc.append(cpu_req_query_metrics_name)

        cpu_reqp_query_metrics = metric_query(cpu_reqp_metrics,cpu_reqp_index,service)
        cpu_reqp_query_metrics_name = metric_query(cpu_reqp_metric_name,cpu_reqp_index_name,service)
        metricnames.append(cpu_reqp_query_metrics)
        metricnames_desc.append(cpu_reqp_query_metrics_name)

        cpu_core_query_metrics = metric_query(cpu_core_metrics,cpu_core_index,service)
        cpu_core_query_metrics_name = metric_query(cpu_core_metric_name,cpu_core_index_name,service)
        metricnames.append(cpu_core_query_metrics)
        metricnames_desc.append(cpu_core_query_metrics_name)

        cpu_corep_query_metrics = metric_query(cpu_corep_metrics,cpu_corep_index,service)
        cpu_corep_query_metrics_name = metric_query(cpu_corep_metric_name,cpu_corep_index_name,service)
        metricnames.append(cpu_corep_query_metrics)
        metricnames_desc.append(cpu_corep_query_metrics_name)

        #NETWORK METRICS STATS

        nrb_query_metrics = metric_query(nrb_metrics,nrb_index,service)
        nrb_query_metrics_name = metric_query(nrb_metric_name,nrb_index_name,service)
        metricnames.append(nrb_query_metrics)
        metricnames_desc.append(nrb_query_metrics_name)

        ntb_query_metrics = metric_query(ntb_metrics,ntb_index,service)
        ntb_query_metrics_name = metric_query(ntb_metric_name,ntb_index_name,service)
        metricnames.append(ntb_query_metrics)
        metricnames_desc.append(ntb_query_metrics_name)

        nrp_query_metrics = metric_query(nrp_metrics,nrp_index,service)
        nrp_query_metrics_name = metric_query(nrp_metric_name,nrp_index_name,service)
        metricnames.append(nrp_query_metrics)
        metricnames_desc.append(nrp_query_metrics_name)

        ntp_query_metrics = metric_query(ntp_metrics,ntp_index,service)
        ntp_query_metrics_name = metric_query(ntp_metric_name,ntp_index_name,service)
        metricnames.append(ntp_query_metrics)
        metricnames_desc.append(ntp_query_metrics_name)

        nrpd_query_metrics = metric_query(nrpd_metrics,nrpd_index,service)
        nrpd_query_metrics_name = metric_query(nrpd_metric_name,nrpd_index_name,service)
        metricnames.append(nrpd_query_metrics)
        metricnames_desc.append(nrpd_query_metrics_name)

        ntpd_query_metrics = metric_query(ntpd_metrics,ntpd_index,service)
        ntpd_query_metrics_name = metric_query(ntpd_metric_name,ntpd_index_name,service)
        metricnames.append(ntpd_query_metrics)
        metricnames_desc.append(ntpd_query_metrics_name)

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
        response = requests.get(PROMETHEUS_URL + RANGE_QUERY_API, params={'query': '{0}'.format(metric), 'start': start_time, 'end': end_time, 'step': RESOLUTION})
        results = response.json()['data']['result']
        for value in results[0]['values']:
            csvset[value[0]].append(value[1])

    return csvset

def write2csv(filename, metricnames, dataset):
    with open(filename, 'w') as file:
        writer = csv.writer(file)
        writer.writerow(['timestamp'] + metricnames)
        for timestamp in sorted(dataset.keys(), reverse=True):
            unix_val = datetime.fromtimestamp(timestamp)
            writer.writerow([unix_val] + dataset[timestamp])
        # for line in dataset:
        #     writer.writerow([line] + dataset[line])

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    main()
