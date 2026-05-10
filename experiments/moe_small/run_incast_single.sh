#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
OUT_DIR="${ROOT_DIR}/experiments/moe_small/output_incast_single"
RAW_OUT_DIR="${ROOT_DIR}/experiments/moe_small/output"
WORKLOAD="${ROOT_DIR}/experiments/moe_small/moe_incast_single.txt"
CONFIG="${ROOT_DIR}/experiments/moe_small/SimAI.moe-small.conf"
TOPO="${ROOT_DIR}/experiments/moe_small/topo_spectrumx_8g_8gps_400g_straggler.txt"
SIM_BIN="${ROOT_DIR}/bin/SimAI_simulator"
THREADS="${THREADS:-2}"
SEND_LAT="${AS_SEND_LAT:-3}"
NVLS_ENABLE="${AS_NVLS_ENABLE:-1}"
RECEIVER_RANK="${SIMAI_INCAST_RECEIVER_RANK:-1}"
SENDER_COUNT="${SIMAI_INCAST_SENDERS:-3}"

mkdir -p "${OUT_DIR}"

run_case() {
  local name="$1"
  local enable="$2"
  local stdout_file="${OUT_DIR}/${name}.stdout.log"
  local fct_file="${OUT_DIR}/${name}.fct.txt"
  local summary_file="${OUT_DIR}/${name}.summary.txt"

  rm -f "${RAW_OUT_DIR}/"{flow,trace,simai.tr,fct,pfc,qlen,bw,rate,cnp}.txt 2>/dev/null || true

  echo "Running ${name} ..."
  AS_SEND_LAT="${SEND_LAT}" \
  AS_NVLS_ENABLE="${NVLS_ENABLE}" \
  SIMAI_FORCE_INCAST_FLOW_MODEL=1 \
  SIMAI_INCAST_RECEIVER_RANK="${RECEIVER_RANK}" \
  SIMAI_INCAST_SENDERS="${SENDER_COUNT}" \
  SIMAI_ENABLE_BARRIER_TAIL_PRIO="${enable}" \
  SIMAI_BARRIER_TAIL_PG=1 \
  "${SIM_BIN}" -t "${THREADS}" -w "${WORKLOAD}" -n "${TOPO}" -c "${CONFIG}" \
    > "${stdout_file}" 2>&1

  cp "${RAW_OUT_DIR}/fct.txt" "${fct_file}"

  python3 - <<'PY' "${fct_file}" "${stdout_file}" "${summary_file}" "${name}"
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
        'size': int(size),
        'start': int(start),
        'fct': int(fct),
        'end': int(start) + int(fct),
    })

big = [r for r in rows if r['size'] >= 67108864]
tails = {}
for r in big:
    key = (r['dst'], r['sport'])
    tails.setdefault(key, []).append(r)

def stats(values):
    values = sorted(values)
    if not values:
        return ('NA', 'NA', 'NA')
    idx = max(0, (len(values) * 95 + 99) // 100 - 1)
    return (sum(values) / len(values), values[idx], values[-1])

tail_fcts = [max(r['fct'] for r in arr) for arr in tails.values()]
tail_ends = [max(r['end'] for r in arr) for arr in tails.values()]
all_fcts = [r['fct'] for r in rows]
all_ends = [r['end'] for r in rows]
stdout = stdout_path.read_text(errors='ignore').splitlines()
enable_count = sum('barrier-tail-prio enable' in ln for ln in stdout)
disable_count = sum('barrier-tail-prio disable' in ln for ln in stdout)
candidate_count = sum('barrier-tail-prio candidate' in ln for ln in stdout)

with summary_path.open('w', encoding='utf-8') as f:
    f.write(f'case={name}\n')
    f.write(f'rows={len(rows)}\n')
    f.write(f'big_rows={len(big)}\n')
    f.write(f'tail_groups={len(tails)}\n')
    f.write(f'barrier_enable_count={enable_count}\n')
    f.write(f'barrier_disable_count={disable_count}\n')
    f.write(f'barrier_candidate_count={candidate_count}\n')
    if all_fcts:
        avg, p95, mx = stats(all_fcts)
        f.write(f'all_avg_fct={avg:.2f}\n')
        f.write(f'all_p95_fct={p95}\n')
        f.write(f'all_max_fct={mx}\n')
        f.write(f'all_max_end={max(all_ends)}\n')
    if tail_fcts:
        avg, p95, mx = stats(tail_fcts)
        f.write(f'tail_avg_fct={avg:.2f}\n')
        f.write(f'tail_p95_fct={p95}\n')
        f.write(f'tail_max_fct={mx}\n')
        f.write(f'tail_max_end={max(tail_ends)}\n')
PY
}

run_case baseline 0
run_case proposed 1

echo "Done. Summaries:"
sed -n '1,20p' "${OUT_DIR}/baseline.summary.txt"
sed -n '1,20p' "${OUT_DIR}/proposed.summary.txt"
