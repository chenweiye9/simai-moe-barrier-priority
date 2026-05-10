#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
OUT_DIR="${ROOT_DIR}/experiments/moe_small/output_random_groups"
RAW_OUT_DIR="${ROOT_DIR}/experiments/moe_small/output"
WORKLOAD="${RANDOM_INCAST_WORKLOAD_FILE:-${ROOT_DIR}/experiments/moe_small/moe_incast_single.txt}"
CONFIG="${ROOT_DIR}/experiments/moe_small/SimAI.moe-small.conf"
TOPO="${RANDOM_INCAST_TOPO_FILE:-${ROOT_DIR}/experiments/moe_small/topo_spectrumx_8g_8gps_400g_uniform.txt}"
SIM_BIN="${ROOT_DIR}/bin/SimAI_simulator"
THREADS="${THREADS:-2}"
SEND_LAT="${AS_SEND_LAT:-3}"
NVLS_ENABLE="${AS_NVLS_ENABLE:-1}"
QPS_PER_CONNECTION="${SIMAI_QPS_PER_CONNECTION:-8}"
GROUP_COUNTS="${RANDOM_INCAST_GROUP_COUNTS:-2,3,4}"
MIN_SENDERS_LIST="${RANDOM_INCAST_MIN_SENDERS:-2,3}"
MAX_SENDERS_LIST="${RANDOM_INCAST_MAX_SENDERS:-4,5,6}"
SEEDS="${RANDOM_INCAST_SEEDS:-11,22,33}"

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
    finish_times = []
    group_finish_times = []
    for line in stdout:
        match = re.search(r'all passes finished at time: (\d+)', line)
        if match:
            finish_times.append(int(match.group(1)))
        group_match = re.search(r'incast-group-complete group:(\d+) tag:(\d+) dst:(\d+) finished_senders:(\d+) total_bytes:(\d+)', line)
        if group_match:
            group_finish_times.append(int(line.split()[0]))
    if finish_times:
        f.write(f'iteration_finish_time={finish_times[-1]}\n')
    f.write(f'incast_group_complete_count={len(group_finish_times)}\n')
    if group_finish_times:
        group_finish_times.sort()
        idx = max(0, (len(group_finish_times) * 95 + 99) // 100 - 1)
        f.write(f'incast_group_avg_finish_time={sum(group_finish_times) / len(group_finish_times):.2f}\n')
        f.write(f'incast_group_p95_finish_time={group_finish_times[idx]}\n')
        f.write(f'incast_group_max_finish_time={group_finish_times[-1]}\n')
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
  local group_count="$2"
  local min_senders="$3"
  local max_senders="$4"
  local seed="$5"
  local enable="$6"
  local stdout_file="${OUT_DIR}/${scenario_id}.stdout.log"
  local fct_file="${OUT_DIR}/${scenario_id}.fct.txt"
  local summary_file="${OUT_DIR}/${scenario_id}.summary.txt"

  rm -f "${RAW_OUT_DIR}/"{flow,trace,simai.tr,fct,pfc,qlen,bw,rate,cnp}.txt 2>/dev/null || true

  AS_SEND_LAT="${SEND_LAT}" \
  AS_NVLS_ENABLE="${NVLS_ENABLE}" \
  SIMAI_FORCE_INCAST_FLOW_MODEL=1 \
  SIMAI_INCAST_USE_ALL_RANKS=1 \
  SIMAI_INCAST_RANDOM_GROUP_COUNT="${group_count}" \
  SIMAI_INCAST_RANDOM_MIN_SENDERS="${min_senders}" \
  SIMAI_INCAST_RANDOM_MAX_SENDERS="${max_senders}" \
  SIMAI_INCAST_RANDOM_SEED="${seed}" \
  SIMAI_QPS_PER_CONNECTION="${QPS_PER_CONNECTION}" \
  SIMAI_ENABLE_BARRIER_TAIL_PRIO="${enable}" \
  SIMAI_BARRIER_TAIL_PG=1 \
  SIMAI_BARRIER_TAIL_MAX_ACTIVE_SRCS="${max_senders}" \
  SIMAI_BARRIER_TAIL_COMPLETED_RATIO=0.25 \
  SIMAI_BARRIER_TAIL_LAGGARD_RATIO=1.10 \
  SIMAI_BARRIER_TAIL_MIN_REMAINING_BYTES=4194304 \
  "${SIM_BIN}" -t "${THREADS}" -w "${WORKLOAD}" -n "${TOPO}" -c "${CONFIG}" \
    > "${stdout_file}" 2>&1

  cp "${RAW_OUT_DIR}/fct.txt" "${fct_file}"
  summarize_case "${fct_file}" "${stdout_file}" "${summary_file}" "${scenario_id}"
}

matrix_csv="${OUT_DIR}/random_groups_matrix.csv"
printf '%s\n' "group_count,min_senders,max_senders,seed,valid_case,baseline_iteration_finish,proposed_iteration_finish,iteration_improve_pct,baseline_group_complete_count,proposed_group_complete_count,baseline_group_max_finish,proposed_group_max_finish,group_max_improve_pct,baseline_all_avg_fct,proposed_all_avg_fct,avg_fct_improve_pct,baseline_tail_max_end,proposed_tail_max_end,tail_end_improve_pct,baseline_rows,proposed_rows,baseline_big_rows,proposed_big_rows,baseline_tail_groups,proposed_tail_groups,proposed_enable_count,proposed_disable_count" > "${matrix_csv}"

for group_count in $(parse_csv_list "${GROUP_COUNTS}"); do
  for min_senders in $(parse_csv_list "${MIN_SENDERS_LIST}"); do
    for max_senders in $(parse_csv_list "${MAX_SENDERS_LIST}"); do
      if [[ "${max_senders}" -lt "${min_senders}" ]]; then
        continue
      fi
      for seed in $(parse_csv_list "${SEEDS}"); do
        scenario_prefix="g${group_count}.min${min_senders}.max${max_senders}.seed${seed}"
        run_case "${scenario_prefix}.baseline" "${group_count}" "${min_senders}" "${max_senders}" "${seed}" 0
        run_case "${scenario_prefix}.laggard" "${group_count}" "${min_senders}" "${max_senders}" "${seed}" 1
        python3 - <<'PY' \
          "${OUT_DIR}/${scenario_prefix}.baseline.summary.txt" \
          "${OUT_DIR}/${scenario_prefix}.laggard.summary.txt" \
          "${group_count}" "${min_senders}" "${max_senders}" "${seed}" >> "${matrix_csv}"
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
group_count, min_senders, max_senders, seed = sys.argv[3:7]

def num(d, key):
    value = d.get(key, '0')
    try:
        if '.' in value:
            return float(value)
        return int(value)
    except ValueError:
        return 0.0

base_iter = float(num(base, 'iteration_finish_time'))
prop_iter = float(num(prop, 'iteration_finish_time'))
base_group_count = float(num(base, 'incast_group_complete_count'))
prop_group_count = float(num(prop, 'incast_group_complete_count'))
base_group_max = float(num(base, 'incast_group_max_finish_time'))
prop_group_max = float(num(prop, 'incast_group_max_finish_time'))
base_avg = float(num(base, 'all_avg_fct'))
prop_avg = float(num(prop, 'all_avg_fct'))
base_tail = float(num(base, 'tail_max_end'))
prop_tail = float(num(prop, 'tail_max_end'))
iter_improve = 0.0 if base_iter == 0 else (base_iter - prop_iter) * 100.0 / base_iter
group_max_improve = 0.0 if base_group_max == 0 else (base_group_max - prop_group_max) * 100.0 / base_group_max
avg_improve = 0.0 if base_avg == 0 else (base_avg - prop_avg) * 100.0 / base_avg
tail_improve = 0.0 if base_tail == 0 else (base_tail - prop_tail) * 100.0 / base_tail
valid_case = int(
    num(base, 'rows') > 0 and
    num(prop, 'rows') > 0 and
    base_iter > 0 and
    prop_iter > 0 and
    base_group_count > 0 and
    prop_group_count > 0
)

print(
    f"{group_count},{min_senders},{max_senders},{seed},{valid_case},"
    f"{int(base_iter)},{int(prop_iter)},{iter_improve:.4f},"
    f"{int(base_group_count)},{int(prop_group_count)},"
    f"{int(base_group_max)},{int(prop_group_max)},{group_max_improve:.4f},"
    f"{base_avg:.2f},{prop_avg:.2f},{avg_improve:.4f},"
    f"{int(base_tail)},{int(prop_tail)},{tail_improve:.4f},"
    f"{int(num(base, 'rows'))},{int(num(prop, 'rows'))},"
    f"{int(num(base, 'big_rows'))},{int(num(prop, 'big_rows'))},"
    f"{int(num(base, 'tail_groups'))},{int(num(prop, 'tail_groups'))},"
    f"{int(num(prop, 'barrier_enable_count'))},{int(num(prop, 'barrier_disable_count'))}"
)
PY
      done
    done
  done
done

python3 - <<'PY' "${matrix_csv}" "${OUT_DIR}/random_groups_ranked.csv"
import csv
import sys
from pathlib import Path

rows = list(csv.DictReader(Path(sys.argv[1]).open(newline='', encoding='utf-8')))
rows = [row for row in rows if row['valid_case'] == '1']
rows = sorted(rows, key=lambda row: float(row['iteration_improve_pct']), reverse=True)
with Path(sys.argv[2]).open('w', newline='', encoding='utf-8') as f:
    if rows:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
PY

echo "Done. Top random-group cases:"
python3 - <<'PY' "${OUT_DIR}/random_groups_ranked.csv"
import csv
import sys
with open(sys.argv[1], newline='', encoding='utf-8') as f:
    rows = list(csv.DictReader(f))
for row in rows[:10]:
    print(
        f"groups={row['group_count']} min={row['min_senders']} max={row['max_senders']} seed={row['seed']} "
        f"iter_improve_pct={row['iteration_improve_pct']} group_max_improve_pct={row['group_max_improve_pct']} tail_end_improve_pct={row['tail_end_improve_pct']} avg_fct_improve_pct={row['avg_fct_improve_pct']} "
        f"rows={row['baseline_rows']}/{row['proposed_rows']} big_rows={row['baseline_big_rows']}/{row['proposed_big_rows']} "
        f"enables={row['proposed_enable_count']} disables={row['proposed_disable_count']}"
    )
PY
