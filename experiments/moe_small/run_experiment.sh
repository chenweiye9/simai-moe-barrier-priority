#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
OUT_DIR="${ROOT_DIR}/experiments/moe_small/output"
WORKLOAD="${ROOT_DIR}/experiments/moe_small/moe_ep8_incast.txt"
CONFIG="${ROOT_DIR}/experiments/moe_small/SimAI.moe-small.conf"
UNIFORM_TOPO="${ROOT_DIR}/Spectrum-X_8g_8gps_400Gbps_H100"
STRAGGLER_TOPO="${ROOT_DIR}/experiments/moe_small/topo_spectrumx_8g_8gps_400g_straggler.txt"
SIM_BIN="${ROOT_DIR}/bin/SimAI_simulator"
THREADS="${THREADS:-2}"
SEND_LAT="${AS_SEND_LAT:-3}"
NVLS_ENABLE="${AS_NVLS_ENABLE:-1}"

mkdir -p "${OUT_DIR}"

summarize_fct_column() {
  local fct_file="$1"
  local awk_filter="$2"
  local label="$3"
  local values_file="${OUT_DIR}/.${label}.vals"
  awk "${awk_filter} { print \$NF }" "${fct_file}" | sort -n > "${values_file}"
  local count
  count=$(wc -l < "${values_file}")
  if [[ "${count}" -eq 0 ]]; then
    echo "${label}_count=0"
    echo "${label}_avg_fct=NA"
    echo "${label}_p95_fct=NA"
    echo "${label}_max_fct=NA"
    rm -f "${values_file}"
    return
  fi

  local p95_idx=$(( (count * 95 + 99) / 100 ))
  local avg_fct
  local p95_fct
  local max_fct
  avg_fct=$(awk '{sum += $1} END {printf "%.2f", sum / NR}' "${values_file}")
  p95_fct=$(awk -v idx="${p95_idx}" 'NR == idx { print; exit }' "${values_file}")
  max_fct=$(tail -n 1 "${values_file}")

  echo "${label}_count=${count}"
  echo "${label}_avg_fct=${avg_fct}"
  echo "${label}_p95_fct=${p95_fct}"
  echo "${label}_max_fct=${max_fct}"
  rm -f "${values_file}"
}

run_case() {
  local name="$1"
  local topo="$2"
  local enable="$3"
  local stdout_file="${OUT_DIR}/${name}.stdout.log"
  local summary_file="${OUT_DIR}/${name}.summary.txt"
  local fct_case_file="${OUT_DIR}/${name}.fct.txt"
  local trace_case_file="${OUT_DIR}/${name}.simai.tr"

  rm -f "${OUT_DIR}/"{flow,trace,simai.tr,fct,pfc,qlen,bw,rate,cnp}.txt 2>/dev/null || true
  rm -f "${OUT_DIR}/simai.tr" 2>/dev/null || true

  echo "Running ${name} ..."
  AS_SEND_LAT="${SEND_LAT}" \
  AS_NVLS_ENABLE="${NVLS_ENABLE}" \
  SIMAI_ENABLE_BARRIER_TAIL_PRIO="${enable}" \
  SIMAI_BARRIER_TAIL_PG=1 \
  "${SIM_BIN}" -t "${THREADS}" -w "${WORKLOAD}" -n "${topo}" -c "${CONFIG}" \
    > "${stdout_file}" 2>&1

  cp "${OUT_DIR}/fct.txt" "${fct_case_file}"
  cp "${OUT_DIR}/simai.tr" "${trace_case_file}"

  local iter_time
  iter_time=$(grep -m1 "all passes finished at time:" "${stdout_file}" | sed -E 's/.*time: ([0-9]+).*/\1/' || true)

  {
    echo "case=${name}"
    echo "topology=${topo}"
    echo "tail_priority_enabled=${enable}"
    echo "threads=${THREADS}"
    echo "as_send_lat=${SEND_LAT}"
    echo "as_nvls_enable=${NVLS_ENABLE}"
    echo "iteration_finish_time=${iter_time:-NA}"
    echo "barrier_enable_count=$(grep -c 'barrier-tail-prio enable' "${stdout_file}" || true)"
    echo "barrier_disable_count=$(grep -c 'barrier-tail-prio disable' "${stdout_file}" || true)"
    summarize_fct_column "${fct_case_file}" '1' "all_flows"
    summarize_fct_column "${fct_case_file}" '$5 >= 16777216' "large_flows"
  } > "${summary_file}"
}

run_case uniform_baseline "${UNIFORM_TOPO}" 0
run_case uniform_proposed "${UNIFORM_TOPO}" 1
run_case straggler_baseline "${STRAGGLER_TOPO}" 0
run_case straggler_proposed "${STRAGGLER_TOPO}" 1

echo "Finished. Summaries:"
sed -n '1,20p' "${OUT_DIR}/uniform_baseline.summary.txt"
sed -n '1,20p' "${OUT_DIR}/uniform_proposed.summary.txt"
sed -n '1,20p' "${OUT_DIR}/straggler_baseline.summary.txt"
sed -n '1,20p' "${OUT_DIR}/straggler_proposed.summary.txt"
