#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
OUT_ROOT="${ROOT_DIR}/experiments/moe_small/output_mixed_ep8"
mkdir -p "${OUT_ROOT}"

run_one() {
  local primary_senders="$1"
  local background_senders="$2"
  local background_bytes="$3"
  local case_dir="${OUT_ROOT}/p${primary_senders}_b${background_senders}_bytes${background_bytes}"

  mkdir -p "${case_dir}"
  rm -rf "${ROOT_DIR}/experiments/moe_small/output_mixed"
  mkdir -p "${ROOT_DIR}/experiments/moe_small/output_mixed"

  AS_SEND_LAT=3 \
  AS_NVLS_ENABLE=1 \
  SIMAI_QPS_PER_CONNECTION=8 \
  SIMAI_INCAST_SENDERS="${primary_senders}" \
  SIMAI_INCAST_BACKGROUND_RECEIVER_RANK=6 \
  SIMAI_INCAST_BACKGROUND_SENDERS="${background_senders}" \
  SIMAI_INCAST_BACKGROUND_BYTES="${background_bytes}" \
  MIXED_WORKLOAD_FILE="${ROOT_DIR}/experiments/moe_small/moe_ep8_incast.txt" \
  bash "${ROOT_DIR}/experiments/moe_small/run_incast_mixed.sh" \
    > "${case_dir}/run.log" 2>&1

  cp "${ROOT_DIR}/experiments/moe_small/output_mixed/"*.summary.txt "${case_dir}/"
}

run_one 5 3 33554432
run_one 5 3 67108864
run_one 5 2 33554432
run_one 7 2 33554432

for f in "${OUT_ROOT}"/*/*.summary.txt; do
  echo "== ${f}"
  sed -n '1,20p' "${f}"
done
