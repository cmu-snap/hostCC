#!/usr/bin/env bash

set -xou pipefail

help() {
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
               [ -s | --stack (=N, IIO stack that the NIC is attached to) ]
               [ -n | --pcien (=N, PCIeN from pcm-iio) ]
               [ -M | --membw (=0/1, disable/enable recording memory bandwidth) ]
               [ -I | --iio (=0/1, disable/enable recording IIO occupancy) ]
               [ -R | --regpcm (=0/1, disable/enable metrics from regular 'pcm' command) ]
               [ -p | --pfc (=0/1, disable/enable recording PFC pause triggers) ]
               [ -i | --intf (interface name, over which to record PFC triggers) ]
               [ -t | --type (=0/1, experiment type -- 0 for TCP, 1 for RDMA) ]
               [ -h | --help  ]"
	exit 2
}

SHORT=H:,o:,d:,c:,C:,r:,T:,b:,f:,P:,s:,n:,M:,I:,R:,p:,i:,t:,h
LONG=home:,outdir:,dur:,cpu_util:,cores:,retx:,tcplog:,bw:,flame:,pcie:,stack:,pcien:,membw:,iio:,regpcm:,pfc:,intf:,type:,help
if [[ $# -eq 0 ]]; then
	help
fi

OPTS=$(getopt -a -n record-host-metrics --options "${SHORT}" --longoptions "${LONG}" -- "$@") || help

eval set -- "${OPTS}"

#default values
home="${HOME}"
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
stack=1
pcien=1
membw=1
iio=0
regpcm=1
pfc=0
intf=ens2f0

# Run pcm commands on the last core.
runcore="$(($(nproc) - 1))"

#TODO: add input config file to specify NUMA node and PCIe slot for PCIe, MemBW and IIO occupancy logging

while :; do
	case "$1" in
	-H | --home)
		home="$2"
		shift 2
		;;
	-o | --outdir)
		outdir="$2"
		shift 2
		;;
	-d | --dur)
		dur="$2"
		shift 2
		;;
	-c | --cpu_util)
		cpu_util="$2"
		shift 2
		;;
	-C | --cores)
		cores="$2"
		shift 2
		;;
	-r | --retx)
		retx="$2"
		shift 2
		;;
	-T | --tcplog)
		tcplog="$2"
		shift 2
		;;
	-b | --bw)
		bw="$2"
		shift 2
		;;
	-f | --flame)
		flame="$2"
		shift 2
		;;
	-P | --pcie)
		pcie="$2"
		shift 2
		;;
	-s | --stack)
		stack="$2"
		shift 2
		;;
	-n | --pcien)
		pcien="$2"
		shift 2
		;;
	-M | --membw)
		membw="$2"
		shift 2
		;;
	-I | --iio)
		iio="$2"
		shift 2
		;;
	-R | --regpcm)
		regpcm="$2"
		shift 2
		;;
	-p | --pfc)
		pfc="$2"
		shift 2
		;;
	-i | --intf)
		intf="$2"
		shift 2
		;;
	-t | --type)
		type="$2"
		shift 2
		;;
	-h | --help)
		help
		;;
	--)
		shift
		break
		;;
	*)
		echo "Unexpected option: $1"
		help
		;;
	esac
done

utils_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

mkdir -pv "${outdir}/logs"    #Directory to store collected logs
mkdir -pv "${outdir}/reports" #Directory to store parsed metrics
# Make these directories accessible to all so that other scripts can store things here.
chmod -R 755 "${outdir}/logs"
chmod -R 755 "${outdir}/reports"

# Load MSR module once (needed by PCM tools).
modprobe msr 2>/dev/null || true

function dump_netstat() {
	local sleep_time="$1"

	echo "Before measurement"
	netstat -s
	echo "Sleeping..."
	sleep "${sleep_time}"
	echo "After measurement"
	netstat -s
}

function dump_pciebw() {
	# Run on core $runcore. Redirect from caller; this just runs the tool.
	sudo taskset -c "${runcore}" "${home}/pcm/build/bin/pcm-iio" 1 -csv="${outdir}/logs/pcie.csv"
}

# PIDs of background metric-collection processes, for targeted cleanup.
declare -A bg_pids

function parse_pciebw() {
	local STACK=$1
	local PCIEN=$2

	# Detect how many sockets are present in the CSV.
	local num_sockets
	num_sockets=$(grep -oP 'Socket[0-9]+' "${outdir}/logs/pcie.csv" | sort -u | wc -l)
	if [[ ${num_sockets} -lt 1 ]]; then
		num_sockets=1
	fi

	# Detect how many parts are present for the target stack/PCIe port.
	local num_parts
	num_parts=$(grep -oP "Socket0,IIO Stack ${STACK} - PCIe${PCIEN},Part[0-9]+" \
		"${outdir}/logs/pcie.csv" | sort -u | wc -l)
	if [[ ${num_parts} -lt 1 ]]; then
		num_parts=1
	fi

	local sock part prefix filter_pat
	for sock in $(seq 0 $((num_sockets - 1))); do
		for part in $(seq 0 $((num_parts - 1))); do
			prefix="Socket${sock}_PCIe${PCIEN}_Part${part}"
			filter_pat="Socket${sock},IIO Stack ${STACK} - PCIe${PCIEN},Part${part}"

			# Skip if no matching rows (e.g., Part1+ may not exist).
			if ! grep -q "${filter_pat}" "${outdir}/logs/pcie.csv" 2>/dev/null; then
				continue
			fi

			# --- Throughput: avg, p50, p99, max (Gbps) ---
			# $4 = write bytes, $5 = read bytes (per 1-second sample).
			{
				grep "${filter_pat}" "${outdir}/logs/pcie.csv" | awk -F ',' -v pfx="${prefix}" '
				{
					wr = $4 / 1000000000.0 * 8
					rd = $5 / 1000000000.0 * 8
					wr_arr[NR] = wr; rd_arr[NR] = rd
					wr_sum += wr; rd_sum += rd
					n++
				}
				END {
					if (n == 0) exit
					# Sort helper (insertion sort, fine for typical N).
					for (i = 2; i <= n; i++) {
						v = wr_arr[i]; j = i
						while (j > 1 && wr_arr[j-1] > v) { wr_arr[j] = wr_arr[j-1]; j-- }
						wr_arr[j] = v
					}
					for (i = 2; i <= n; i++) {
						v = rd_arr[i]; j = i
						while (j > 1 && rd_arr[j-1] > v) { rd_arr[j] = rd_arr[j-1]; j-- }
						rd_arr[j] = v
					}
					# ceil(n * fraction) for correct percentile indexing.
					p50 = int(n * 0.50 + 0.999999); if (p50 < 1) p50 = 1; if (p50 > n) p50 = n
					p99 = int(n * 0.99 + 0.999999); if (p99 < 1) p99 = 1; if (p99 > n) p99 = n

					printf "%s_avg_PCIe_wr_tput: %.3f\n", pfx, wr_sum / n
					printf "%s_p50_PCIe_wr_tput: %.3f\n", pfx, wr_arr[p50]
					printf "%s_p99_PCIe_wr_tput: %.3f\n", pfx, wr_arr[p99]
					printf "%s_max_PCIe_wr_tput: %.3f\n", pfx, wr_arr[n]

					printf "%s_avg_PCIe_rd_tput: %.3f\n", pfx, rd_sum / n
					printf "%s_p50_PCIe_rd_tput: %.3f\n", pfx, rd_arr[p50]
					printf "%s_p99_PCIe_rd_tput: %.3f\n", pfx, rd_arr[p99]
					printf "%s_max_PCIe_rd_tput: %.3f\n", pfx, rd_arr[n]
				}'

				# --- IOTLB: avg counts and miss rate ---
				# $7 = IOTLB hits, $8 = IOTLB misses.
				grep "${filter_pat}" "${outdir}/logs/pcie.csv" | awk -F ',' -v pfx="${prefix}" '
				{
					hits += $7; misses += $8; n++
				}
				END {
					if (n == 0) exit
					printf "%s_avg_IOTLB_hit_count: %.3f\n", pfx, hits / n
					printf "%s_avg_IOTLB_miss_count: %.3f\n", pfx, misses / n
					total = hits + misses
					if (total > 0)
						printf "%s_IOTLB_miss_rate: %.6f\n", pfx, misses / total
					else
						printf "%s_IOTLB_miss_rate: 0.000000\n", pfx
				}'

				# --- TLP counters: MRd, CPL, CPLd ---
				# $6 = Inbound TLP MRd (memory read requests from device).
				# $9 = Inbound TLP CPL  (completions without data).
				# $10 = Inbound TLP CPLd (completions with data).
				grep "${filter_pat}" "${outdir}/logs/pcie.csv" | awk -F ',' -v pfx="${prefix}" '
				{
					mrd += $6; cpl += $9; cpld += $10; n++
				}
				END {
					if (n == 0) exit
					printf "%s_avg_TLP_MRd: %.3f\n", pfx, mrd / n
					printf "%s_avg_TLP_CPL: %.3f\n", pfx, cpl / n
					printf "%s_avg_TLP_CPLd: %.3f\n", pfx, cpld / n
					if (mrd > 0)
						printf "%s_avg_CPLd_per_MRd: %.3f\n", pfx, cpld / mrd
				}'
			} >>"${outdir}/reports/pcie.rpt"
		done
	done

	# Also emit legacy unprefixed keys for backward compatibility
	# (Socket0, Part0 only).
	local legacy_pat="Socket0,IIO Stack ${STACK} - PCIe${PCIEN},Part0"
	if grep -q "${legacy_pat}" "${outdir}/logs/pcie.csv" 2>/dev/null; then
		{
			echo "avg_PCIe_wr_tput: $(grep "${legacy_pat}" "${outdir}/logs/pcie.csv" | awk -F ',' '{ sum += $4/1000000000.0; n++ } END { if (n > 0) printf "%.3f", sum / n * 8 ; }')"
			echo "avg_PCIe_rd_tput: $(grep "${legacy_pat}" "${outdir}/logs/pcie.csv" | awk -F ',' '{ sum += $5/1000000000.0; n++ } END { if (n > 0) printf "%.3f", sum / n * 8 ; }')"
			echo "avg_IOTLB_hit_count: $(grep "${legacy_pat}" "${outdir}/logs/pcie.csv" | awk -F ',' '{ sum += $7; n++ } END { if (n > 0) printf "%.3f", sum / n; }')"
			echo "avg_IOTLB_miss_count: $(grep "${legacy_pat}" "${outdir}/logs/pcie.csv" | awk -F ',' '{ sum += $8; n++ } END { if (n > 0) printf "%.3f", sum / n; }')"
		} >>"${outdir}/reports/pcie.rpt"
	fi
}

function dump_membw() {
	# Run on core $runcore
	sudo taskset -c "${runcore}" "${home}/pcm/build/bin/pcm-memory" 1 -columns=5
}

function dump_standard_pcm() {
	# Run on core $runcore
	sudo taskset -c "${runcore}" "${home}/pcm/build/bin/pcm" 1 -csv="${outdir}/logs/pcm.csv"
}

function parse_membw() {
	#TODO: make more general, parse memory bandwidth for any given number of sockets
	# In MB/s
	{
		echo "avg_Node0_rd_bw: $(grep "NODE 0 Mem Read" "${outdir}/logs/membw.log" | awk '{ sum += $8; n++ } END { if (n > 0) printf "%f\n", sum / n; }')"
		echo "avg_Node0_wr_bw: $(grep "NODE 0 Mem Write" "${outdir}/logs/membw.log" | awk '{ sum += $7; n++ } END { if (n > 0) printf "%f\n", sum / n; }')"
		echo "avg_Node0_total_bw: $(grep "NODE 0 Memory" "${outdir}/logs/membw.log" | awk '{ sum += $6; n++ } END { if (n > 0) printf "%f\n", sum / n; }')"
		echo "avg_Node1_rd_bw: $(grep "NODE 1 Mem Read" "${outdir}/logs/membw.log" | awk '{ sum += $16; n++ } END { if (n > 0) printf "%f\n", sum / n; }')"
		echo "avg_Node1_wr_bw: $(grep "NODE 1 Mem Write" "${outdir}/logs/membw.log" | awk '{ sum += $14; n++ } END { if (n > 0) printf "%f\n", sum / n; }')"
		echo "avg_Node1_total_bw: $(grep "NODE 1 Memory" "${outdir}/logs/membw.log" | awk '{ sum += $12; n++ } END { if (n > 0) printf "%f\n", sum / n; }')"
	} >>"${outdir}/reports/membw.rpt"
	# Disabled because our servers only have at most 2 sockets
	#echo "avg_Node2_rd_bw: " $(cat $outdir/logs/membw.log | grep "NODE 2 Mem Read" | awk '{ sum += $24; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> $outdir/reports/membw.rpt
	#echo "avg_Node2_wr_bw: " $(cat $outdir/logs/membw.log | grep "NODE 2 Mem Write" | awk '{ sum += $21; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> $outdir/reports/membw.rpt
	#echo "avg_Node2_total_bw: " $(cat $outdir/logs/membw.log | grep "NODE 2 Memory" | awk '{ sum += $18; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> $outdir/reports/membw.rpt
	#echo "avg_Node3_rd_bw: " $(cat $outdir/logs/membw.log | grep "NODE 3 Mem Read" | awk '{ sum += $32; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> $outdir/reports/membw.rpt
	#echo "avg_Node3_wr_bw: " $(cat $outdir/logs/membw.log | grep "NODE 3 Mem Write" | awk '{ sum += $28; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> $outdir/reports/membw.rpt
	#echo "avg_Node3_total_bw: " $(cat $outdir/logs/membw.log | grep "NODE 3 Memory" | awk '{ sum += $24; n++ } END { if (n > 0) printf "%f\n", sum / n; }')  >> $outdir/reports/membw.rpt
}

function collect_pfc() {
	# Assuming PFC is enabled for QoS 0.
	sudo ethtool -S "${intf}" | grep pause >"${outdir}/logs/pause.before.log"
	sleep "${dur}"
	sudo ethtool -S "${intf}" | grep pause >"${outdir}/logs/pause.after.log"

	local pause_before pause_duration_before pause_after pause_duration_after
	pause_before=$(grep "tx_prio0_pause" "${outdir}/logs/pause.before.log" | head -n1 | awk '{ printf $2 }')
	pause_duration_before=$(grep "tx_prio0_pause_duration" "${outdir}/logs/pause.before.log" | awk '{ printf $2 }')
	pause_after=$(grep "tx_prio0_pause" "${outdir}/logs/pause.after.log" | head -n1 | awk '{ printf $2 }')
	pause_duration_after=$(grep "tx_prio0_pause_duration" "${outdir}/logs/pause.after.log" | awk '{ printf $2 }')

	# Default to 0 if grep found nothing.
	: "${pause_before:=0}" "${pause_duration_before:=0}"
	: "${pause_after:=0}" "${pause_duration_after:=0}"

	{
		echo "pauses_before: ${pause_before}"
		echo "pause_duration_before: ${pause_duration_before}"
		echo "pauses_after: ${pause_after}"
		echo "pause_duration_after: ${pause_duration_after}"
	} >>"${outdir}/logs/pause.log"

	# Compute rates using awk instead of piping into lua.
	awk -v after="${pause_after}" -v before="${pause_before}" \
		-v d="${dur}" 'BEGIN { printf "%.6f\n", (after - before) / d }' \
		>"${outdir}/reports/pause.rpt"
	awk -v after="${pause_duration_after}" -v before="${pause_duration_before}" \
		-v d="${dur}" 'BEGIN { printf "%.6f\n", (after - before) / d }' \
		>>"${outdir}/reports/pause.rpt"
}

function compile_if_needed() {
	local source_file="$1"
	local executable="$2"

	# Check if the executable exists and if the source file is newer
	if [[ ! -f ${executable} ]] || [[ ${source_file} -nt ${executable} ]]; then
		echo "Compiling ${source_file}..."
		if gcc -o "${executable}" "${source_file}"; then
			echo "Compilation successful."
		else
			echo "Compilation failed."
		fi
	else
		echo "No need to recompile."
	fi
}

if [[ ${type} == 0 ]]; then
	echo "Collecting TCP experiment metrics..."

	if [[ ${cpu_util} == 1 ]]; then
		echo "Collecting CPU utilization for cores ${cores}..."
		sar -P "${cores}" 1 "${dur}" 2>/dev/null | tr -s " " | grep ":" >"${outdir}/logs/cpu_util.log" &
		bg_pids[sar]=$!
		sleep "${dur}"
		kill -TERM "${bg_pids[sar]}" 2>/dev/null || true
		wait "${bg_pids[sar]}" 2>/dev/null || true
		unset 'bg_pids[sar]'
		python3 "${utils_dir}/cpu_util.py" "${outdir}/logs/cpu_util.log" >"${outdir}/reports/cpu_util.rpt"
	fi

	# if ["$bw" = 1 ]
	# then
	# echo "Collecting app bandwidth..."
	# echo "Avg_iperf_tput: " $(cat $outdir/logs/iperf.bw.log | grep "60.*-90.*" | awk  '{ sum += $7; n++ } END { if (n > 0) printf "%.3f", sum/1000; }') > $outdir/reports/iperf.bw.rpt
	# fi

	if [[ ${retx} == 1 ]]; then
		echo "Collecting retransmission rate..."
		dump_netstat "${dur}" >"${outdir}/logs/retx.log"
		grep -E "segment|TCPLostRetransmit" "${outdir}/logs/retx.log" >"${outdir}/logs/retx.out"
		python3 "${utils_dir}/print_retx_rate.py" "${outdir}/logs/retx.out" "${dur}" >"${outdir}/reports/retx.rpt"
	fi

	if [[ ${tcplog} == 1 ]]; then
		echo "Collecting tcplog..."
		tracedir=/sys/kernel/debug/tracing
		echo >"${tracedir}/trace"
		echo 1 >"${tracedir}/events/tcp/tcp_probe/enable"
		sleep "${dur}"
		echo 0 >"${tracedir}/events/tcp/tcp_probe/enable"
		sleep 1
		cp "${tracedir}/trace" "${outdir}/logs/tcp.trace.log"
		echo >"${tracedir}/trace"
		python3 "${utils_dir}/parse_tcplog.py" "${outdir}"
	fi

elif [[ ${type} == 1 ]]; then
	echo "Collecting RDMA experiment metrics..."
	if [[ ${pfc} == 1 ]]; then
		echo "Collecting PFC triggers at RDMA server..."
		collect_pfc
	fi

else
	echo "Incorrect type..."
	help
fi

if [[ ${pcie} == 1 ]]; then
	echo "Collecting PCIe bandwidth..."
	dump_pciebw >/dev/null 2>&1 &
	bg_pids[pciebw]=$!
	sleep "${dur}"
	sudo kill -INT "${bg_pids[pciebw]}" 2>/dev/null || true
	wait "${bg_pids[pciebw]}" 2>/dev/null || true
	unset 'bg_pids[pciebw]'
	parse_pciebw "${stack}" "${pcien}"
fi

if [[ ${membw} == 1 ]]; then
	echo "Collecting Memory bandwidth..."
	dump_membw >"${outdir}/logs/membw.log" 2>&1 &
	bg_pids[membw]=$!
	sleep "${dur}"
	sudo kill -INT "${bg_pids[membw]}" 2>/dev/null || true
	wait "${bg_pids[membw]}" 2>/dev/null || true
	unset 'bg_pids[membw]'
	parse_membw
fi

if [[ ${iio} == 1 ]]; then
	echo "Collecting IIO occupancy..."
	compile_if_needed "${utils_dir}/collect_iio_occ.c" "${utils_dir}/collect_iio_occ"
	# Run from outdir/logs so iio.csv is written there directly.
	(cd "${outdir}/logs" && taskset -c "${runcore}" "${utils_dir}/collect_iio_occ" "$(nproc)" "${runcore}" "${stack}") >/dev/null 2>&1 &
	bg_pids[iio]=$!
	sleep "${dur}"
	sudo kill -INT "${bg_pids[iio]}" 2>/dev/null || true
	wait "${bg_pids[iio]}" 2>/dev/null || true
	unset 'bg_pids[iio]'
fi

if [[ ${regpcm} == 1 ]]; then
	echo "Collecting standard PCM metrics..."
	dump_standard_pcm >/dev/null 2>&1 &
	bg_pids[pcm]=$!
	sleep "${dur}"
	sudo kill -INT "${bg_pids[pcm]}" 2>/dev/null || true
	wait "${bg_pids[pcm]}" 2>/dev/null || true
	unset 'bg_pids[pcm]'
fi

echo "record-host-metrics.sh finished"
exit 0
