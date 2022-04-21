#!/bin/bash
# Copyright 2021 Hewlett Packard Enterprise Development LP
#
# This script to visualize metrics dashboards on the terminal, like a simplified and minimalist version of Grafana for terminal.
#

PROGNAME=${0##*/}

function usage()
{
  cat << EO
   Usage: $PROGNAME [flags]

   Example: $PROGNAME -c critical_services_dashboard.json -r 5s -d 2h

   Flags:
EO
  cat <<EO | column -s\& -t
   --help & show help
   --version & show the application version
   --list & list available dashboards
   -c|--cfg  & dashboard file
   -r|--refresh-interval & the interval to refresh the dashboard. Default value 10s
   -d|--relative-duration & the relative duration from now to load the graph.
                          &  if this isn't specified, the grafterm will display the data starting at the beginning.
   -s|--start & the time the dashboard will start in time.
              &  accepts 2 formats, relative time from now based on duration(e.g.: 24h, 15m),
              &  or fixed duration in ISO 8601 (e.g.: 2021-10-15T03:30:11+00:00).
              &  if set it disables relative duration flag.
   -e|--end & the time the dashboard will end in time.
            &  accepts 2 formats, relative time from now based on duration(e.g.: 24h, 15m),
            &  or fixed duration in ISO 8601 (e.g.: 2021-10-15T03:30:11+00:00).
EO
}

function get_grafterm_pod_name()
{
  grafterm_pod=$(kubectl get po -n sysmgmt-health | grep grafterm | awk '{print $1}')
  echo $grafterm_pod
}

# Option strings
SHORT=h,l:,v:,c:,r:,d:,s:,e:
LONG=help,version,list,cfg:,refresh-interval:,relative-duration:,start:,end::

# read the options
OPTS=$(getopt --options $SHORT --long $LONG --name "$0" -- "$@")

if [ $? != 0 ] ; then echo "Failed to parse options...exiting." >&2 ; usage; exit 1 ; fi
if [[ $# -eq 0 ]] ; then usage; exit 1 ; fi

eval set -- "$OPTS"

# extract options and their arguments into variables.
while true ; do
  case "$1" in
    --help )
      usage
      exit 1
      ;;
    --version )
      grafterm_pod=$(get_grafterm_pod_name)
      if [ "x$grafterm_pod" == "x" ]; then echo "Error: grafterm pod is not running"; exit 1; fi
      echo $(kubectl exec --stdin --tty -n sysmgmt-health $grafterm_pod -- grafterm --version)
      exit 1
      ;;
    --list )
      grafterm_pod=$(get_grafterm_pod_name)
      if [ "x$grafterm_pod" == "x" ]; then echo "Error: grafterm pod is not running"; exit 1; fi
      echo $(kubectl exec --stdin --tty -n sysmgmt-health $grafterm_pod -- ls /grafterm)
      exit 1
      ;;
    -c | --cfg )
      CFG="$2"
      shift 2
      ;;
    -r | --refresh-interval )
      RINTERVAL="$2"
      shift 2
      ;;
    -d | --relative-duration )
      RDURATION="$2"
      shift 2
      ;;
    -s | --start )
      START="$2"
      shift 2
      ;;
    -e | --end )
      END="$2"
      shift 2
      ;;
    -- )
      shift
      break
      ;;
    *)
      echo "Input error!"
      usage
      exit 1
      ;;
  esac
done


if [ "x" == "x$CFG" ]; then echo "Error: cfg argument is required"; usage; exit 1; fi

grafterm_pod=$(get_grafterm_pod_name)

command_args=" "

# Add commandline arguments to the kubectl exec command
if [ "x" != "x$RINTERVAL" ]; then
  command_args=$command_args"-r $RINTERVAL "
fi

if [ "x" != "x$RDURATION" ]; then
  command_args=$command_args"-d $RDURATION "
fi

if [ "x" != "x$START" ]; then
  command_args=$command_args"-d $START "
fi

if [ "x" != "x$END" ]; then
  command_args=$command_args"-d $END "
fi

command_args=" -c $CFG"$command_args

kubectl exec --stdin --tty -n sysmgmt-health $grafterm_pod -- grafterm $command_args
