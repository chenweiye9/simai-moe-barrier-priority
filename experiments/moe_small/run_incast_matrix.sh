#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
OUT_DIR="${ROOT_DIR}/experiments/moe_small/output_matrix"
RAW_OUT_DIR="${ROOT_DIR}/experiments/moe_small/output"
CONFIG="${ROOT_DIR}/experiments/moe_small/SimAI.moe-small.conf"
SIM_BIN="${ROOT_DIR}/bin/SimAI_simulator"
THREADS="${THREADS:-2}"
SEND_LAT="${AS_SEND_LAT:-3}"
NVLS_ENABLE="${AS_NVLS_ENABLE:-1}"
RECEIVER_RANK="${SIMAI_INCAST_RECEIVER_RANK:-1}"
WORKLOADS="${MATRIX_WORKLOADS:-single}"
SENDERS_LIST="${MATRIX_SENDERS:-3,5,7}"
QPS_LIST="${MATRIX_QPS:-1,8,16}"
TOPO_LIST="${MATRIX_TOPOLOGIES:-uniform400,straggler200,straggler100,straggler50,straggler25}"
LAGGARD_COMPLETED_RATIO="${SIMAI_BARRIER_TAIL_COMPLETED_RATIO:-0.25}"
LAGGARD_RATIO="${SIMAI_BARRIER_TAIL_LAGGARD_RATIO:-1.10}"
LAGGARD_MIN_REMAINING="${SIMAI_BARRIER_TAIL_MIN_REMAINING_BYTES:-4194304}"
LAGGARD_PG="${SIMAI_BARRIER_TAIL_PG:-1}"

mkdir -p "${OUT_DIR}"

declare -A WORKLOAD_FILES=(
  [single]="${ROOT_DIR}/experiments/moe_small/moe_incast_single.txt"
  [repeated]="${ROOT_DIR}/experiments/moe_small/moe_ep8_incast.txt"
)

declare -A TOPO_FILES=(
  [uniform400]="${ROOT_DIR}/experiments/moe_small/topo_spectrumx_8g_8gps_400g_uniform.txt"
  [straggler200]="${ROOT_DIR}/experiments/moe_small/topo_spectrumx_8g_8gps_400g_straggler200.txt"
  [straggler100]="${ROOT_DIR}/experiments/moe_small/topo_spectrumx_8g_8gps_400g_straggler.txt"
  [straggler50]="${ROOT_DIR}/experiments/moe_small/topo_spectrumx_8g_8gps_400g_straggler50.txt"
  [straggler25]="${ROOT_DIR}/experiments/moe_small/topo_spectrumx_8g_8gps_400g_straggler25.txt"
)

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
  local scenario_id="$1"
  local case_name="$2"
  local workload_file="$3"
  local topo_file="$4"
  local senders="$5"
  local qps="$6"
  local enable="$7"
  local max_active="$8"
  local completed_ratio="$9"
  local laggard_ratio="${10}"
  local min_remaining="${11}"

  local stdout_file="${OUT_DIR}/${scenario_id}.${case_name}.stdout.log"
  local fct_file="${OUT_DIR}/${scenario_id}.${case_name}.fct.txt"
  local summary_file="${OUT_DIR}/${scenario_id}.${case_name}.summary.txt"

  rm -f "${RAW_OUT_DIR}/"{flow,trace,simai.tr,fct,pfc,qlen,bw,rate,cnp}.txt 2>/dev/null || true

  echo "Running ${scenario_id} / ${case_name}"
  AS_SEND_LAT="${SEND_LAT}" \
  AS_NVLS_ENABLE="${NVLS_ENABLE}" \
  SIMAI_FORCE_INCAST_FLOW_MODEL=1 \
  SIMAI_INCAST_USE_ALL_RANKS=1 \
  SIMAI_INCAST_RECEIVER_RANK="${RECEIVER_RANK}" \
  SIMAI_INCAST_SENDERS="${senders}" \
  SIMAI_QPS_PER_CONNECTION="${qps}" \
  SIMAI_ENABLE_BARRIER_TAIL_PRIO="${enable}" \
  SIMAI_BARRIER_TAIL_PG="${LAGGARD_PG}" \
  SIMAI_BARRIER_TAIL_MAX_ACTIVE_SRCS="${max_active}" \
  SIMAI_BARRIER_TAIL_COMPLETED_RATIO="${completed_ratio}" \
  SIMAI_BARRIER_TAIL_LAGGARD_RATIO="${laggard_ratio}" \
  SIMAI_BARRIER_TAIL_MIN_REMAINING_BYTES="${min_remaining}" \
  "${SIM_BIN}" -t "${THREADS}" -w "${workload_file}" -n "${topo_file}" -c "${CONFIG}" \
    > "${stdout_file}" 2>&1

  cp "${RAW_OUT_DIR}/fct.txt" "${fct_file}"
  summarize_case "${fct_file}" "${stdout_file}" "${summary_file}" "${scenario_id}.${case_name}"
}

matrix_csv="${OUT_DIR}/matrix.csv"
printf '%s\n' "workload,topology,senders,qps,baseline_all_avg_fct,laggard_all_avg_fct,avg_fct_improve_pct,baseline_tail_max_end,laggard_tail_max_end,tail_end_improve_pct,baseline_enable_count,laggard_enable_count,laggard_candidate_count" > "${matrix_csv}"

for workload_name in $(parse_csv_list "${WORKLOADS}"); do
  workload_file="${WORKLOAD_FILES[${workload_name}]}"
  if [[ -z "${workload_file:-}" || ! -f "${workload_file}" ]]; then
    echo "Unknown workload: ${workload_name}" >&2
    exit 1
  fi
  for topo_name in $(parse_csv_list "${TOPO_LIST}"); do
    topo_file="${TOPO_FILES[${topo_name}]}"
    if [[ -z "${topo_file:-}" || ! -f "${topo_file}" ]]; then
      echo "Unknown topology: ${topo_name}" >&2
      exit 1
    fi
    for senders in $(parse_csv_list "${SENDERS_LIST}"); do
      for qps in $(parse_csv_list "${QPS_LIST}"); do
        scenario_id="${workload_name}.${topo_name}.s${senders}.q${qps}"
        run_case "${scenario_id}" baseline "${workload_file}" "${topo_file}" "${senders}" "${qps}" 0 1 1.0 1.0 0
        run_case "${scenario_id}" laggard "${workload_file}" "${topo_file}" "${senders}" "${qps}" 1 "${senders}" "${LAGGARD_COMPLETED_RATIO}" "${LAGGARD_RATIO}" "${LAGGARD_MIN_REMAINING}"

        python3 - <<'PY' \
          "${OUT_DIR}/${scenario_id}.baseline.summary.txt" \
          "${OUT_DIR}/${scenario_id}.laggard.summary.txt" \
          "${workload_name}" "${topo_name}" "${senders}" "${qps}" >> "${matrix_csv}"
import sys
from pathlib import Path

def load_summary(path_str):
    data = {}
    for line in Path(path_str).read_text(encoding='utf-8').splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            data[k] = v
    return data

baseline = load_summary(sys.argv[1])
laggard = load_summary(sys.argv[2])
workload_name, topo_name, senders, qps = sys.argv[3:7]

def num(d, key):
    value = d.get(key, '0')
    try:
        if '.' in value:
            return float(value)
        return int(value)
    except ValueError:
        return 0.0

base_avg = float(num(baseline, 'all_avg_fct'))
lag_avg = float(num(laggard, 'all_avg_fct'))
base_tail_end = float(num(baseline, 'tail_max_end'))
lag_tail_end = float(num(laggard, 'tail_max_end'))
avg_improve = 0.0 if base_avg == 0 else (base_avg - lag_avg) * 100.0 / base_avg
tail_improve = 0.0 if base_tail_end == 0 else (base_tail_end - lag_tail_end) * 100.0 / base_tail_end

print(
    f"{workload_name},{topo_name},{senders},{qps},"
    f"{base_avg:.2f},{lag_avg:.2f},{avg_improve:.4f},"
    f"{int(base_tail_end)},{int(lag_tail_end)},{tail_improve:.4f},"
    f"{int(num(baseline, 'barrier_enable_count'))},{int(num(laggard, 'barrier_enable_count'))},"
    f"{int(num(laggard, 'barrier_candidate_count'))}"
)
PY
      done
    done
  done
done

python3 - <<'PY' "${matrix_csv}" "${OUT_DIR}/matrix_ranked_tail_end.csv" "${OUT_DIR}/matrix_ranked_avg_fct.csv"
import csv
import sys
from pathlib import Path

matrix_path = Path(sys.argv[1])
tail_rank_path = Path(sys.argv[2])
avg_rank_path = Path(sys.argv[3])

rows = list(csv.DictReader(matrix_path.open(newline='', encoding='utf-8')))

tail_rows = sorted(rows, key=lambda row: float(row['tail_end_improve_pct']), reverse=True)
avg_rows = sorted(rows, key=lambda row: float(row['avg_fct_improve_pct']), reverse=True)

with tail_rank_path.open('w', newline='', encoding='utf-8') as f:
    writer = csv.DictWriter(f, fieldnames=rows[0].keys())
    writer.writeheader()
    writer.writerows(tail_rows)

with avg_rank_path.open('w', newline='', encoding='utf-8') as f:
    writer = csv.DictWriter(f, fieldnames=rows[0].keys())
    writer.writeheader()
    writer.writerows(avg_rows)
PY

echo "Matrix complete."
echo "Top tail-end improvements:"
python3 - <<'PY' "${OUT_DIR}/matrix_ranked_tail_end.csv"
import csv
import sys

with open(sys.argv[1], newline='', encoding='utf-8') as f:
    rows = list(csv.DictReader(f))

for row in rows[:10]:
    print(
        f"{row['workload']} {row['topology']} senders={row['senders']} qps={row['qps']} "
        f"tail_end_improve_pct={row['tail_end_improve_pct']} avg_fct_improve_pct={row['avg_fct_improve_pct']}"
    )
PY
