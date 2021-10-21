# Critical Service Resource Consumption Tool

This tool has three python scripts with parameterized start and stop times 
to collect metrics for the below services and NCNs. We are using Prometheus
api client to collect the metrics from Prometheus database and exporting them into csv files. 

We can easily edit/remove  ‘services’ python list variable available starting of the script as below:
services = ['cray-smd', 'cray-bss', 'cray-capmc', 'cray-hbtd', 'cray-cps', 'slurm']


## Requirements
* Executes on an NCN
* Requires being logged in as root

# Modules

## crc_istio_prom_csv.py 


In this script we are collecting istio http response times (P50,P95 and P99) 
and http response codes (2xx/3xx/4xx/5xx) using istio prometheus as 
datasource

### Usage:
```

ncn-m001:~/ram/18oct/working # python crc_istio_prom_csv.py
ERROR:root:You should use -h or --host to specify your prometheus server's url, e.g. http://prometheus:9090

Metrics2CSV Help Info
    metrics2csv.py -h <prometheus_url> -c <container_name> [-o <outputfile>]
or: metrics2csv.py --host=<prometheus_url> --container=<container_name> [--outfile=<outputfile>]
---
Additional options: --start=<start_timestamp_or_rfc3339> --end=<end_timestamp_or_rfc3339> --period=<get_for_most_recent_period(int miniutes)>
                    use start&end or only use period


```

Below example command(with parameterized start and stop time) will generate istio.csv file:

```
python crc_istio_prom_csv.py -h http://10.35.128.193:9090 -o istio.csv -s 10s --start=2021-10-18T02:10:30.781Z --end=2021-10-18T04:11:00.781Z
INFO:root:Querying metric names succeeded, metric number: 42
INFO:root:Querying metric values succeeded, rows of data: 361


## crc_query_csv.py 


In this script we are collecting memory usage, CPU usage, and network bandwidth etc., from 
sysmgmt-health prometheus datasource and exporting them into a csv file.

The resulted csv file will have below metrics:
    memory request bytes
    memory usage bytes
    memory request
    memory limits
    memory limits %
    memory usage(RSS)
    memory usage(cache)
    memory usage(swap)
    cpu usage
    cpu requests
    cpu requests %
    cpu limits
    cpu limits %
    total network receive bytes
    total network transmit bytes
    total network receive packets
    total network transmit packets
    total receive packets dropped
    total transmit packets dropped
	

   


### Usage
```

ncn-m001:~ #ppython crc_query_csv.py
ERROR:root:You should use -h or --host to specify your prometheus server's url, e.g. http://prometheus:9090

Metrics2CSV Help Info
    metrics2csv.py -h <prometheus_url> -c <container_name> [-o <outputfile>]
or: metrics2csv.py --host=<prometheus_url> --container=<container_name> [--outfile=<outputfile>]
---
Additional options: --start=<start_timestamp_or_rfc3339> --end=<end_timestamp_or_rfc3339> --period=<get_for_most_recent_period(int miniutes)>
                    use start&end or only use period

```

Below example command(with parameterized start and stop time) will generate shs.csv file:


```
python crc_query_csv.py -h http://10.35.128.140:9090  -o shs.csv -s 10s --start=2021-10-18T02:10:30.781Z --end=2021-10-18T04:11:00.781Z
INFO:root:Querying metric names succeeded, metric number: 114
INFO:root:Querying metric values succeeded, rows of data: 361

## ncn_query_csv.py


In this script we are collecting memory usage, CPU usage, and network bandwidth for non-compute nodes, from sysmgmt-health prometheus datasource and exporting them into a csv file.

The resulted csv file will have below metrics:
     NCN node memory buffers bytes
     NCN node memory free bytes
     NCN node memory cache bytes
     NCN node memory used bytes

     NCN node cpu usage

     NCN node network receive bytes
     NCN node network transmitted bytes


### Usage
```

ncn-m001:~ #python ncn_query_csv.py
ERROR:root:You should use -h or --host to specify your prometheus server's url, e.g. http://prometheus:9090

Metrics2CSV Help Info
    metrics2csv.py -h <prometheus_url> -c <container_name> [-o <outputfile>]
or: metrics2csv.py --host=<prometheus_url> --container=<container_name> [--outfile=<outputfile>]
---
Additional options: --start=<start_timestamp_or_rfc3339> --end=<end_timestamp_or_rfc3339> --period=<get_for_most_recent_period(int miniutes)>
                    use start&end or only use period

```

Below example command(with parameterized start and stop time) will generate ncn.csv file:

```
python ncn_query_csv.py  -h http://10.35.128.140:9090  -o ncn.csv -s 10s --start=2021-10-18T02:10:30.781Z --end=2021-10-18T04:11:00.781Z
INFO:root:Querying metric names succeeded, metric number: 49
INFO:root:Querying metric values succeeded, rows of data: 361

