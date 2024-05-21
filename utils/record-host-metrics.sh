#!/usr/bin/env bash

set -eoux pipefail

help()
{
    echo "Usage: record-host-metrics [ -H | --home (home directory)]
               [ -o | --outdir (name of the output directory which will store the records; default=test) ]
               [ -d | --dur (duration in seconds to record each metric; default=30s) ]
               [ -c | --cpu_util (=0/1, disable/enable recording cpu utilization) ) ]
               [ -C | --cores (comma separated values of cpu cores to log utilization, eg., '0,4,8,12') ) ]
               [ -r | --retx (=0/1, disable/enable recording retransmission rate (should be done at TCP senders) ) ]
               [ -T | --tcplog (=0/1, disable/enable recording TCP log (should be done at TCP senders) ) ]
               [ -b | --bw (=0/1, disable/enable recording app-level bandwidth ) ]
               [ -f | --flame (=0/1, disable/enable recording flamegraph (for cores specified via -C/--cores option) ) ]
               [ -P | --pcie (=0/1, disable/enable recording PCIe bandwidth) ]
               [ -M | --membw (=0/1, disable/enable recording memory bandwidth) ]
               [ -I | --iio (=0/1, disable/enable recording IIO occupancy) ]
               [ -R | --regpcm (=0/1, disable/enable metrics from regular 'pcm' command) ]
               [ -p | --pfc (=0/1, disable/enable recording PFC pause triggers) ]
               [ -i | --intf (interface name, over which to record PFC triggers) ]
               [ -t | --type (=0/1, experiment type -- 0 for TCP, 1 for RDMA) ]
               [ -h | --help  ]"
    exit 2
}

SHORT=H:,o:,d:,c:,C:,r:,T:,b:,f:,P:,M:,I:,R:,p:,i:,t:,h
LONG=home:,outdir:,dur:,cpu_util:,cores:,retx:,tcplog:,bw:,flame:,pcie:,membw:,iio:,regpcm:,pfc:,intf:,type:,help
OPTS=$(getopt -a -n record-host-metrics --options $SHORT --longoptions $LONG -- "$@")

VALID_ARGUMENTS=$# # Returns the count of arguments that are in short or long options

if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi

eval set -- "$OPTS"

#default values
home='$HOME'
outdir='test'
dur=30
type=1
cpu_util=1
cores=0
retx=0
tcplog=0
flame=0
bw=1
pcie=1
membw=1
iio=0
regpcm=1
pfc=0
intf=ens2f0
stack=1

# Run pcm commands on the last core.
runcore="$(($(nproc) - 1))"

#TODO: add input config file to specify NUMA node and PCIe slot for PCIe, MemBW and IIO occupancy logging


while :
do
  case "$1" in
     -H | --home )
      home="$2"
      shift 2
      ;;
    -o | --outdir )
      outdir="$2"
      shift 2
      ;;
    -d | --dur )
      dur="$2"
      shift 2
      ;;
    -c | --cpu_util )
      cpu_util="$2"
      shift 2
      ;;
    -C | --cores )
      cores="$2"
      shift 2
      ;;
    -r | --retx )
      retx="$2"
      shift 2
      ;;
    -T | --tcplog )
      tcplog="$2"
      shift 2
      ;;
    -b | --bw )
      bw="$2"
      shift 2
      ;;
    -f | --flame )
      flame="$2"
      shift 2
      ;;
    -P | --pcie )
      pcie="$2"
      shift 2
      ;;
    -M | --membw )
      membw="$2"
      shift 2
      ;;
    -I | --iio )
      iio="$2"
      shift 2
      ;;
    -R | --regpcm )
      regpcm="$2"
      shift 2
      ;;
    -p | --pfc )
      pfc="$2"
      shift 2
      ;;
    -i | --intf )
      intf="$2"
      shift 2
      ;;
    -t | --type )
      type="$2"
      shift 2
      ;;
    -h | --help)
      help
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "Unexpected option: $1"
      help
      ;;
  esac
done

utils_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

mkdir -pv $outdir/logs #Directory to store collected logs
mkdir -pv $outdir/reports #Directory to store parsed metrics
# Make these directories accessible to all so that other scripts can store things here.
chmod -R 777 $outdir/logs
chmod -R 777 $outdir/reports

function dump_netstat() {
    local SLEEP_TIME=$1

    echo "Before measurement"
    netstat -s
    echo "Sleeping..."
    sleep $SLEEP_TIME
    echo "After measurement"
    netstat -s

}

function dump_pciebw() {
    modprobe msr
    # Run on core $runcore
    sudo taskset -c $runcore $home/pcm/build/bin/pcm-iio 1 -csv=$outdir/logs/pcie.csv &
}

function parse_pciebw() {
    #TODO: make more general, parse PCIe bandwidth for any given socket and IIO stack
    local STACK=$1
    echo "PCIe_wr_tput: " $(cat $outdir/logs/pcie.csv | grep "Socket0,IIO Stack $STACK - PCIe1,Part0" | awk -F ',' '{ sum += $4/1000000000.0; n++ } END { if (n > 0) printf "%.3f", sum / n * 8 ; }') > $outdir/reports/pcie.rpt
    echo "PCIe_rd_tput: " $(cat $outdir/logs/pcie.csv | grep "Socket0,IIO Stack $STACK - PCIe1,Part0" | awk -F ',' '{ sum += $5/1000000000.0; n++ } END { if (n > 0) printf "%0.3f", sum / n * 8 ; }') >> $outdir/reports/pcie.rpt
    echo "IOTLB_hits: " $(cat $outdir/logs/pcie.csv | grep "Socket0,IIO Stack $STACK - PCIe1,Part0" | awk -F ',' '{ sum += $8; n++ } END { if (n > 0) printf "%0.3f", sum / n; }') >> $outdir/reports/pcie.rpt
    echo "IOTLB_misses: " $(cat $outdir/logs/pcie.csv | grep "Socket0,IIO Stack $STACK - PCIe1,Part0" | awk -F ',' '{ sum += $9; n++ } END { if (n > 0) printf "%0.3f", sum / n; }') >> $outdir/reports/pcie.rpt
}

function dump_membw() {
    modprobe msr
    # Run on core $runcore
    sudo taskset -c $runcore $home/pcm/build/bin/pcm-memory 1 -columns=5
}

function dump_standard_pcm() {
    # Run on core $runcore
    sudo taskset -c $runcore $home/pcm/build/bin/pcm 1 -csv=$outdir/logs/pcm.csv
}

function parse_membw() {
    #TODO: make more general, parse memory bandwidth for any given number of sockets
    echo "Node0_rd_bw: " $(cat $outdir/logs/membw.log | grep "NODE 0 Mem Read" | awk '{ sum += $8; n++ } END { if (n > 0) printf "%f\n", sum / n; }') > $outdir/reports/membw.rpt
    echo "Node0_wr_bw: " $(cat $outdir/logs/membw.log | grep "NODE 0 Mem Write" | awk '{ sum += $7; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> $outdir/reports/membw.rpt
    echo "Node0_total_bw: " $(cat $outdir/logs/membw.log | grep "NODE 0 Memory" | awk '{ sum += $6; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> $outdir/reports/membw.rpt
    echo "Node1_rd_bw: " $(cat $outdir/logs/membw.log | grep "NODE 1 Mem Read" | awk '{ sum += $16; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> $outdir/reports/membw.rpt
    echo "Node1_wr_bw: " $(cat $outdir/logs/membw.log | grep "NODE 1 Mem Write" | awk '{ sum += $14; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> $outdir/reports/membw.rpt
    echo "Node1_total_bw: " $(cat $outdir/logs/membw.log | grep "NODE 1 Memory" | awk '{ sum += $12; n++ } END { if (n > 0) printf "%f\n", sum / n; }') >> $outdir/reports/membw.rpt
    echo "Node2_rd_bw: " $(cat $outdir/logs/membw.log | grep "NODE 2 Mem Read" | awk '{ sum += $24; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> $outdir/reports/membw.rpt
    echo "Node2_wr_bw: " $(cat $outdir/logs/membw.log | grep "NODE 2 Mem Write" | awk '{ sum += $21; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> $outdir/reports/membw.rpt
    echo "Node2_total_bw: " $(cat $outdir/logs/membw.log | grep "NODE 2 Memory" | awk '{ sum += $18; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> $outdir/reports/membw.rpt
    echo "Node3_rd_bw: " $(cat $outdir/logs/membw.log | grep "NODE 3 Mem Read" | awk '{ sum += $32; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> $outdir/reports/membw.rpt
    echo "Node3_wr_bw: " $(cat $outdir/logs/membw.log | grep "NODE 3 Mem Write" | awk '{ sum += $28; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> $outdir/reports/membw.rpt
    echo "Node3_total_bw: " $(cat $outdir/logs/membw.log | grep "NODE 3 Memory" | awk '{ sum += $24; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> $outdir/reports/membw.rpt
}

function collect_pfc() {
    #assuming PFC is enabled for QoS 0
    sudo ethtool -S $intf | grep pause > $outdir/logs/pause.before.log
    sleep $dur
    sudo ethtool -S $intf | grep pause > $outdir/logs/pause.after.log

    pause_before=$(cat $outdir/logs/pause.before.log | grep "tx_prio0_pause" | head -n1 | awk '{ printf $2 }')
    pause_duration_before=$(cat $outdir/logs/pause.before.log | grep "tx_prio0_pause_duration" | awk '{ printf $2 }')
    pause_after=$(cat $outdir/logs/pause.after.log | grep "tx_prio0_pause" | head -n1 | awk '{ printf $2 }')
    pause_duration_after=$(cat $outdir/logs/pause.after.log | grep "tx_prio0_pause_duration" | awk '{ printf $2 }')

    echo "pauses_before: "$pause_before > $outdir/logs/pause.log
    echo "pause_duration_before: "$pause_duration_before >> $outdir/logs/pause.log
    echo "pauses_after: "$pause_after >> $outdir/logs/pause.log
    echo "pause_duration_after: "$pause_duration_after >> $outdir/logs/pause.log

    # echo $pause_before, $pause_after
    echo "print(($pause_after - $pause_before)/$dur)" | lua > $outdir/reports/pause.rpt

    # echo $pause_duration_before, $pause_duration_after
    echo "print(($pause_duration_after - $pause_duration_before)/$dur)" | lua >> $outdir/reports/pause.rpt
}


function compile_if_needed() {
    local source_file=$1
    local executable=$2

    # Check if the executable exists and if the source file is newer
    if [ ! -f "$executable" ] || [ "$source_file" -nt "$executable" ]; then
        echo "Compiling $source_file..."
        gcc -o "$executable" "$source_file"
        if [ $? -eq 0 ]; then
            echo "Compilation successful."
        else
            echo "Compilation failed."
        fi
    else
        echo "No need to recompile."
    fi
}



if [ "$type" = 0 ]
then
    echo "Collecting TCP experiment metrics..."

    if [ "$cpu_util" = 1 ]
    then
      echo "Collecting CPU utilization for cores $cores..."
      sar -P $cores 1 1000 > $outdir/logs/cpu_util.log &
      sleep $dur
      sudo pkill -9 -f "sar"
      python3 $utils_dir/cpu_util.py $outdir/logs/cpu_util.log > $outdir/reports/cpu_util.rpt
    fi

    # if ["$bw" = 1 ]
    # then
    # echo "Collecting app bandwidth..."
    # echo "Avg_iperf_tput: " $(cat $outdir/logs/iperf.bw.log | grep "60.*-90.*" | awk  '{ sum += $7; n++ } END { if (n > 0) printf "%.3f", sum/1000; }') > $outdir/reports/iperf.bw.rpt
    # fi

    if [ "$retx" = 1 ]
    then
      echo "Collecting retransmission rate..."
      dump_netstat $dur > $outdir/logs/retx.log
      cat $outdir/logs/retx.log | grep -E "segment|TCPLostRetransmit" > retx.out
      python3 $utils_dir/print_retx_rate.py retx.out $dur > $outdir/reports/retx.rpt
    fi

    if [ "$tcplog" = 1 ]
    then
      echo "Collecting tcplog..."
      cd /sys/kernel/debug/tracing
      echo > trace
      echo 1 > events/tcp/tcp_probe/enable
      sleep 2
      echo 0 > events/tcp/tcp_probe/enable
      sleep 2
      cp trace $outdir/logs/tcp.trace.log
      echo > trace
      cd -
      python3 $utils_dir/parse_tcplog.py $outdir
    fi

elif [ "$type" = 1 ]
then
    echo "Collecting RDMA experiment metrics..."
    if [ "$pfc" = 1 ]
    then
      echo "Collecting PFC triggers at RDMA server..."
      collect_pfc
    fi

else
    echo "Incorrect type..."
    help
fi


if [ "$pcie" = 1 ]
then
    echo "Collecting PCIe bandwidth..."
    pushd $home/hostCC/utils
    dump_pciebw
    sleep $dur
    sudo pkill -9 -f "pcm"
    parse_pciebw $stack
    popd
fi


if [ "$membw" = 1 ]
then
    echo "Collecting Memory bandwidth..."
    dump_membw > $outdir/logs/membw.log &
    sleep $dur
    sudo pkill -9 -f "pcm"
    parse_membw
fi


if [ "$iio" = 1 ]
then
    echo "Collecting IIO occupancy..."
    # gcc collect_iio_occ.c -o collect_iio_occ
    compile_if_needed $utils_dir/collect_iio_occ.c $utils_dir/collect_iio_occ
    # Run on core 28
    taskset -c 28 $utils_dir/collect_iio_occ &
    sleep $dur
    sudo pkill -2 -f $utils_dir/collect_iio_occ
    sleep 5
    mv iio.log $outdir/logs/iio.log
    #TODO: make more generic and add a parser to create report for iio occupancy logging from userspace
fi

if [ "$regpcm" = 1 ]
then
    echo "Collecting standard PCM metrics..."
    dump_standard_pcm
    sleep $dur
    sudo pkill -9 -f "pcm"
fi
