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

    csvset = query_metric_values(metricnames=metricnames, metricnames_desc=metricnames_desc)
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
    #services = ['cray-smd', 'cray-bss', 'cray-capmc', 'cray-hbtd', 'cray-cps']
    #service http responses

    #istio_r200_metrics = 'sum(irate(istio_requests_total{reporter="destination",destination_service=~".*.*",response_code=~"2[0-9][0-9]"}[5m])) / sum(irate(istio_requests_total{reporter="destination",destination_service=~"cray-smd.services.svc.cluster.local"}[5m])) * 100'
    #istio_r200_metrics = 'sum(rate(istio_requests_total{reporter="destination",destination_service=~"cray-smd.services.svc.cluster.local",response_code!~"5.*"}[5m])) / sum(rate(istio_requests_total{reporter="destination",destination_service=~"cray-smd.services.svc.cluster.local"}[5m])) * 100'

    #istio_r200_metrics = 'sum(rate(istio_requests_total{reporter="destination",destination_service=~"cray-smd.services.svc.cluster.local",response_code=~"2[0-9][0-9]"}[5m])) / sum(rate(istio_requests_total{reporter="destination",destination_service=~"cray-smd.services.svc.cluster.local"}[5m])) * 100'

    #istio_response_metrics = 'round(sum(rate(istio_requests_total{reporter="destination",destination_service=~".*APP.*",response_code=~"RESPONSE"}[5m])) / sum(rate(istio_requests_total{reporter="destination",destination_service=~".*APP.*"}[5m])), 0.001) * 100'
    istio_response_metrics = 'sum(rate(istio_requests_total{reporter="destination",destination_service=~".*APP.*",response_code=~"RESPONSE"}[5m])) / sum(rate(istio_requests_total{reporter="destination",destination_service=~".*APP.*"}[5m])) * 100'
    
    p50_metrics = '(histogram_quantile(0.50, sum(rate(istio_request_duration_milliseconds_bucket{reporter="destination",destination_service=~".*APP.*"}[1m])) by (le)) / 1000) or histogram_quantile(0.50, sum(irate(istio_request_duration_seconds_bucket{reporter="destination",destination_service=~".*APP.*"}[1m])) by (le))'

    p90_metrics = '(histogram_quantile(0.90, sum(irate(istio_request_duration_milliseconds_bucket{reporter="destination",destination_service=~".*APP.*"}[1m])) by (le)) / 1000) or histogram_quantile(0.90, sum(irate(istio_request_duration_seconds_bucket{reporter="destination",destination_service=~".*APP.*"}[1m])) by (le))' 
    #service http responses metrics description

    p99_metrics = '(histogram_quantile(0.99, sum(irate(istio_request_duration_milliseconds_bucket{reporter="destination",destination_service=~".*APP.*"}[1m])) by (le)) / 1000) or histogram_quantile(0.99, sum(irate(istio_request_duration_seconds_bucket{reporter="destination",destination_service=~".*APP.*"}[1m])) by (le))'

    istio_r2xx_name = 'APP  2XX %'
    istio_r3xx_name = 'APP  3XX %'
    istio_r4xx_name = 'APP  4XX %'
    istio_r5xx_name = 'APP  5XX %'

    response_2xx = '2[0-9][0-9]'
    response_3xx = '3[0-9][0-9]'
    response_4xx = '4[0-9][0-9]'
    response_5xx = '5[0-9][0-9]'

    p50_name = 'APP P50 server request duration sec'
    p90_name = 'APP P90 server request duration sec'
    p99_name = 'APP P99 server request duration sec'

    for service in services:

        #ISTIO SERVICE STATS

        #ISTIO SERVICE STATS FOR RESPONSE CODE 2XX

        istio_r2xx_metrics = istio_response_metrics.replace("APP", service,2)
        istio_r2xx_metrics = istio_r2xx_metrics.replace("RESPONSE",response_2xx)
        istio_r2xx_query_metrics_name = istio_r2xx_name.replace("APP", service)
        #print(istio_r2xx_metrics)
        metricnames.append(istio_r2xx_metrics)
        metricnames_desc.append(istio_r2xx_query_metrics_name)

        #ISTIO SERVICE STATS FOR RESPONSE CODE 3XX

        istio_r3xx_metrics = istio_response_metrics.replace("APP", service,2)
        istio_r3xx_metrics = istio_r3xx_metrics.replace("RESPONSE",response_3xx)
        istio_r3xx_query_metrics_name = istio_r3xx_name.replace("APP", service)
        #print(istio_r3xx_metrics)
        metricnames.append(istio_r3xx_metrics)
        metricnames_desc.append(istio_r3xx_query_metrics_name)

        #ISTIO SERVICE STATS FOR RESPONSE CODE 4XX
   
        istio_r4xx_metrics = istio_response_metrics.replace("APP", service,2)
        istio_r4xx_metrics = istio_r4xx_metrics.replace("RESPONSE",response_4xx)
        istio_r4xx_query_metrics_name = istio_r4xx_name.replace("APP", service)
        #print(istio_r4xx_metrics)
        metricnames.append(istio_r4xx_metrics)
        metricnames_desc.append(istio_r4xx_query_metrics_name)

        #ISTIO SERVICE STATS FOR RESPONSE CODE 5XX

        istio_r5xx_metrics = istio_response_metrics.replace("APP", service,2)
        istio_r5xx_metrics = istio_r5xx_metrics.replace("RESPONSE",response_5xx)
        istio_r5xx_query_metrics_name = istio_r5xx_name.replace("APP", service)
        #print(istio_r5xx_metrics)
        metricnames.append(istio_r5xx_metrics)
        metricnames_desc.append(istio_r5xx_query_metrics_name)

        #ISTIO SERVICE STATS FOR P50 SERVER
       
        p50_service_metric = p50_metrics.replace("APP", service,2)
        p50_query_metrics_name = p50_name.replace("APP", service)
        metricnames.append(p50_service_metric)
        metricnames_desc.append(p50_query_metrics_name)

        #ISTIO SERVICE STATS FOR P90 SERVER

        p90_service_metric = p90_metrics.replace("APP", service,2)
        p90_query_metrics_name = p90_name.replace("APP", service)
        metricnames.append(p90_service_metric)
        metricnames_desc.append(p90_query_metrics_name)

        #ISTIO SERVICE STATS FOR P90 SERVER

        p99_service_metric = p99_metrics.replace("APP", service,2)
        p99_query_metrics_name = p99_name.replace("APP", service)
        metricnames.append(p99_service_metric)
        metricnames_desc.append(p99_query_metrics_name)

    return metricnames, metricnames_desc;


def query_metric_values(metricnames, metricnames_desc):
    csvset = dict()
    mnd_length = len(metricnames_desc)
    mnd_length_new = mnd_length
    
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
        if len(results) == 0:
            #print(metric)
            #print(metricnames.index(metric))
            metricnames_desc.pop(metricnames.index(metric) - (mnd_length - mnd_length_new))
            mnd_length_new = mnd_length_new - 1
        else:
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

