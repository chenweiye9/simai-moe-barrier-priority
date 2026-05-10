#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
OUT_DIR="${ROOT_DIR}/experiments/moe_small/output_mixed_matrix"
RAW_OUT_DIR="${ROOT_DIR}/experiments/moe_small/output"
WORKLOAD="${MIXED_WORKLOAD_FILE:-${ROOT_DIR}/experiments/moe_small/moe_incast_single.txt}"
CONFIG="${ROOT_DIR}/experiments/moe_small/SimAI.moe-small.conf"
TOPO="${MIXED_TOPO_FILE:-${ROOT_DIR}/experiments/moe_small/topo_spectrumx_8g_8gps_400g_uniform.txt}"
SIM_BIN="${ROOT_DIR}/bin/SimAI_simulator"
THREADS="${THREADS:-2}"
SEND_LAT="${AS_SEND_LAT:-3}"
NVLS_ENABLE="${AS_NVLS_ENABLE:-1}"
RECEIVER_RANK="${SIMAI_INCAST_RECEIVER_RANK:-1}"
BACKGROUND_RECEIVER_RANK="${SIMAI_INCAST_BACKGROUND_RECEIVER_RANK:-6}"
QPS_PER_CONNECTION="${SIMAI_QPS_PER_CONNECTION:-8}"
PRIMARY_SENDERS_LIST="${MIXED_PRIMARY_SENDERS:-5,7}"
BACKGROUND_SENDERS_LIST="${MIXED_BACKGROUND_SENDERS:-1,2,3}"
BACKGROUND_BYTES_LIST="${MIXED_BACKGROUND_BYTES:-33554432,67108864,134217728}"

mkdir -p "${OUT_DIR}"

parse_csv_list() {
  local raw="$1"
  echo "${raw}" | tr ',' ' '
}

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
  local scenario_id="$1"
  local primary_senders="$2"
  local background_senders="$3"
  local background_bytes="$4"
  local enable="$5"
  local stdout_file="${OUT_DIR}/${scenario_id}.stdout.log"
  local fct_file="${OUT_DIR}/${scenario_id}.fct.txt"
  local summary_file="${OUT_DIR}/${scenario_id}.summary.txt"

  rm -f "${RAW_OUT_DIR}/"{flow,trace,simai.tr,fct,pfc,qlen,bw,rate,cnp}.txt 2>/dev/null || true

  AS_SEND_LAT="${SEND_LAT}" \
  AS_NVLS_ENABLE="${NVLS_ENABLE}" \
  SIMAI_FORCE_INCAST_FLOW_MODEL=1 \
  SIMAI_INCAST_USE_ALL_RANKS=1 \
  SIMAI_INCAST_RECEIVER_RANK="${RECEIVER_RANK}" \
  SIMAI_INCAST_SENDERS="${primary_senders}" \
  SIMAI_INCAST_BACKGROUND_RECEIVER_RANK="${BACKGROUND_RECEIVER_RANK}" \
  SIMAI_INCAST_BACKGROUND_SENDERS="${background_senders}" \
  SIMAI_INCAST_BACKGROUND_BYTES="${background_bytes}" \
  SIMAI_QPS_PER_CONNECTION="${QPS_PER_CONNECTION}" \
  SIMAI_ENABLE_BARRIER_TAIL_PRIO="${enable}" \
  SIMAI_BARRIER_TAIL_PG=1 \
  SIMAI_BARRIER_TAIL_MAX_ACTIVE_SRCS="${primary_senders}" \
  SIMAI_BARRIER_TAIL_COMPLETED_RATIO=0.25 \
  SIMAI_BARRIER_TAIL_LAGGARD_RATIO=1.10 \
  SIMAI_BARRIER_TAIL_MIN_REMAINING_BYTES=4194304 \
  "${SIM_BIN}" -t "${THREADS}" -w "${WORKLOAD}" -n "${TOPO}" -c "${CONFIG}" \
    > "${stdout_file}" 2>&1

  cp "${RAW_OUT_DIR}/fct.txt" "${fct_file}"
  summarize_case "${fct_file}" "${stdout_file}" "${summary_file}" "${scenario_id}"
}

matrix_csv="${OUT_DIR}/mixed_matrix.csv"
printf '%s\n' "primary_senders,background_senders,background_bytes,baseline_all_avg_fct,proposed_all_avg_fct,avg_fct_improve_pct,baseline_tail_max_end,proposed_tail_max_end,tail_end_improve_pct,proposed_enable_count,proposed_disable_count" > "${matrix_csv}"

for primary_senders in $(parse_csv_list "${PRIMARY_SENDERS_LIST}"); do
  for background_senders in $(parse_csv_list "${BACKGROUND_SENDERS_LIST}"); do
    for background_bytes in $(parse_csv_list "${BACKGROUND_BYTES_LIST}"); do
      scenario_prefix="p${primary_senders}.b${background_senders}.bytes${background_bytes}"
      run_case "${scenario_prefix}.baseline" "${primary_senders}" "${background_senders}" "${background_bytes}" 0
      run_case "${scenario_prefix}.laggard" "${primary_senders}" "${background_senders}" "${background_bytes}" 1
      python3 - <<'PY' \
        "${OUT_DIR}/${scenario_prefix}.baseline.summary.txt" \
        "${OUT_DIR}/${scenario_prefix}.laggard.summary.txt" \
        "${primary_senders}" "${background_senders}" "${background_bytes}" >> "${matrix_csv}"
import sys
from pathlib import Path

def load(path_str):
    d = {}
    for line in Path(path_str).read_text(encoding='utf-8').splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            d[k] = v
    return d

base = load(sys.argv[1])
prop = load(sys.argv[2])
primary_senders, background_senders, background_bytes = sys.argv[3:6]

def num(d, key):
    value = d.get(key, '0')
    try:
        if '.' in value:
            return float(value)
        return int(value)
    except ValueError:
        return 0.0

base_avg = float(num(base, 'all_avg_fct'))
prop_avg = float(num(prop, 'all_avg_fct'))
base_tail = float(num(base, 'tail_max_end'))
prop_tail = float(num(prop, 'tail_max_end'))
avg_improve = 0.0 if base_avg == 0 else (base_avg - prop_avg) * 100.0 / base_avg
tail_improve = 0.0 if base_tail == 0 else (base_tail - prop_tail) * 100.0 / base_tail

print(
    f"{primary_senders},{background_senders},{background_bytes},"
    f"{base_avg:.2f},{prop_avg:.2f},{avg_improve:.4f},"
    f"{int(base_tail)},{int(prop_tail)},{tail_improve:.4f},"
    f"{int(num(prop, 'barrier_enable_count'))},{int(num(prop, 'barrier_disable_count'))}"
)
PY
    done
  done
done

python3 - <<'PY' "${matrix_csv}" "${OUT_DIR}/mixed_matrix_ranked.csv"
import csv
import sys
from pathlib import Path

rows = list(csv.DictReader(Path(sys.argv[1]).open(newline='', encoding='utf-8')))
rows = sorted(rows, key=lambda row: float(row['tail_end_improve_pct']), reverse=True)
with Path(sys.argv[2]).open('w', newline='', encoding='utf-8') as f:
    writer = csv.DictWriter(f, fieldnames=rows[0].keys())
    writer.writeheader()
    writer.writerows(rows)
PY

echo "Done. Top mixed cases:"
python3 - <<'PY' "${OUT_DIR}/mixed_matrix_ranked.csv"
import csv
import sys
with open(sys.argv[1], newline='', encoding='utf-8') as f:
    rows = list(csv.DictReader(f))
for row in rows[:10]:
    print(
        f"primary={row['primary_senders']} bg={row['background_senders']} "
        f"bg_bytes={row['background_bytes']} tail_end_improve_pct={row['tail_end_improve_pct']} "
        f"avg_fct_improve_pct={row['avg_fct_improve_pct']} enables={row['proposed_enable_count']} disables={row['proposed_disable_count']}"
    )
PY
