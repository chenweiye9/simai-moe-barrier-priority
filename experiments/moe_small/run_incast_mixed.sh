#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
OUT_DIR="${ROOT_DIR}/experiments/moe_small/output_mixed"
RAW_OUT_DIR="${ROOT_DIR}/experiments/moe_small/output"
WORKLOAD="${MIXED_WORKLOAD_FILE:-${ROOT_DIR}/experiments/moe_small/moe_incast_single.txt}"
CONFIG="${ROOT_DIR}/experiments/moe_small/SimAI.moe-small.conf"
TOPO="${MIXED_TOPO_FILE:-${ROOT_DIR}/experiments/moe_small/topo_spectrumx_8g_8gps_400g_uniform.txt}"
SIM_BIN="${ROOT_DIR}/bin/SimAI_simulator"
THREADS="${THREADS:-2}"
SEND_LAT="${AS_SEND_LAT:-3}"
NVLS_ENABLE="${AS_NVLS_ENABLE:-1}"
RECEIVER_RANK="${SIMAI_INCAST_RECEIVER_RANK:-1}"
SENDER_COUNT="${SIMAI_INCAST_SENDERS:-5}"
QPS_PER_CONNECTION="${SIMAI_QPS_PER_CONNECTION:-8}"
BACKGROUND_RECEIVER_RANK="${SIMAI_INCAST_BACKGROUND_RECEIVER_RANK:-6}"
BACKGROUND_SENDERS="${SIMAI_INCAST_BACKGROUND_SENDERS:-2}"
BACKGROUND_BYTES="${SIMAI_INCAST_BACKGROUND_BYTES:-67108864}"

mkdir -p "${OUT_DIR}"

summarize_case() {
  local fct_file="$1"
  local stdout_file="$2"
  local summary_file="$3"
  local case_name="$4"

  python3 - <<'PY' "${fct_file}" "${stdout_file}" "${summary_file}" "${case_name}"
import re
import sys
from pathlib import Path

fct_path = Path(sys.argv[1])
stdout_path = Path(sys.argv[2])
summary_path = Path(sys.argv[3])
name = sys.argv[4]

pat = re.compile(r'(0b[0-9a-fA-F]{6})\s+(0b[0-9a-fA-F]{6})\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)')
rows = []
for m in pat.finditer(fct_path.read_text(errors='ignore')):
    src, dst, sport, dport, size, start, fct, standalone = m.groups()
    rows.append({
        'src': src,
        'dst': dst,
        'sport': int(sport),
        'dport': int(dport),
        'size': int(size),
        'start': int(start),
        'fct': int(fct),
        'end': int(start) + int(fct),
    })

big = [r for r in rows if r['size'] >= 1048576]
groups = {}
for r in big:
    key = (r['dst'], r['sport'])
    groups.setdefault(key, []).append(r)

def stats(values):
    values = sorted(values)
    if not values:
        return None
    idx = max(0, (len(values) * 95 + 99) // 100 - 1)
    return (sum(values) / len(values), values[idx], values[-1])

all_fcts = [r['fct'] for r in rows]
tail_fcts = [max(r['fct'] for r in arr) for arr in groups.values()]
tail_ends = [max(r['end'] for r in arr) for arr in groups.values()]
stdout = stdout_path.read_text(errors='ignore').splitlines()

with summary_path.open('w', encoding='utf-8') as f:
    f.write(f'case={name}\n')
    f.write(f'rows={len(rows)}\n')
    f.write(f'big_rows={len(big)}\n')
    f.write(f'tail_groups={len(groups)}\n')
    f.write(f'barrier_enable_count={sum("barrier-tail-prio enable" in ln for ln in stdout)}\n')
    f.write(f'barrier_disable_count={sum("barrier-tail-prio disable" in ln for ln in stdout)}\n')
    f.write(f'barrier_candidate_count={sum("barrier-tail-prio candidate" in ln for ln in stdout)}\n')
    if all_fcts:
        avg, p95, mx = stats(all_fcts)
        f.write(f'all_avg_fct={avg:.2f}\n')
        f.write(f'all_p95_fct={p95}\n')
        f.write(f'all_max_fct={mx}\n')
        f.write(f'all_max_end={max(r["end"] for r in rows)}\n')
    if tail_fcts:
        avg, p95, mx = stats(tail_fcts)
        f.write(f'tail_avg_fct={avg:.2f}\n')
        f.write(f'tail_p95_fct={p95}\n')
        f.write(f'tail_max_fct={mx}\n')
        f.write(f'tail_max_end={max(tail_ends)}\n')
PY
}

run_case() {
  local name="$1"
  local enable="$2"
  local max_active="$3"
  local completed_ratio="$4"
  local laggard_ratio="$5"
  local min_remaining="$6"
  local stdout_file="${OUT_DIR}/${name}.stdout.log"
  local fct_file="${OUT_DIR}/${name}.fct.txt"
  local summary_file="${OUT_DIR}/${name}.summary.txt"

  rm -f "${RAW_OUT_DIR}/"{flow,trace,simai.tr,fct,pfc,qlen,bw,rate,cnp}.txt 2>/dev/null || true

  AS_SEND_LAT="${SEND_LAT}" \
  AS_NVLS_ENABLE="${NVLS_ENABLE}" \
  SIMAI_FORCE_INCAST_FLOW_MODEL=1 \
  SIMAI_INCAST_USE_ALL_RANKS=1 \
  SIMAI_INCAST_RECEIVER_RANK="${RECEIVER_RANK}" \
  SIMAI_INCAST_SENDERS="${SENDER_COUNT}" \
  SIMAI_INCAST_BACKGROUND_RECEIVER_RANK="${BACKGROUND_RECEIVER_RANK}" \
  SIMAI_INCAST_BACKGROUND_SENDERS="${BACKGROUND_SENDERS}" \
  SIMAI_INCAST_BACKGROUND_BYTES="${BACKGROUND_BYTES}" \
  SIMAI_QPS_PER_CONNECTION="${QPS_PER_CONNECTION}" \
  SIMAI_ENABLE_BARRIER_TAIL_PRIO="${enable}" \
  SIMAI_BARRIER_TAIL_PG=1 \
  SIMAI_BARRIER_TAIL_MAX_ACTIVE_SRCS="${max_active}" \
  SIMAI_BARRIER_TAIL_COMPLETED_RATIO="${completed_ratio}" \
  SIMAI_BARRIER_TAIL_LAGGARD_RATIO="${laggard_ratio}" \
  SIMAI_BARRIER_TAIL_MIN_REMAINING_BYTES="${min_remaining}" \
  "${SIM_BIN}" -t "${THREADS}" -w "${WORKLOAD}" -n "${TOPO}" -c "${CONFIG}" \
    > "${stdout_file}" 2>&1

  cp "${RAW_OUT_DIR}/fct.txt" "${fct_file}"
  summarize_case "${fct_file}" "${stdout_file}" "${summary_file}" "${name}"
}

run_case baseline 0 1 1.0 1.0 0
run_case laggard_tail 1 "${SENDER_COUNT}" 0.25 1.10 4194304

echo "Done. Summaries:"
sed -n '1,20p' "${OUT_DIR}/baseline.summary.txt"
sed -n '1,20p' "${OUT_DIR}/laggard_tail.summary.txt"
