#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VM_HOST="${SIMAI_VM_HOST:-192.168.48.129}"
VM_USER="${SIMAI_VM_USER:-weiye}"
VM_PASS="${SIMAI_VM_PASS:-886868}"
VM_WORKDIR="${SIMAI_VM_WORKDIR:-/home/weiye/simai-moe-barrier-priority-main}"
VM_VMrun_BIN="${SIMAI_VMRUN_BIN:-/Applications/VMware Fusion.app/Contents/Library/vmrun}"
VM_VMX="${SIMAI_VM_VMX:-/Users/weiye/Virtual Machines.localized/moe.vmwarevm/moe.vmx}"
SSH_CONNECT_TIMEOUT="${SIMAI_VM_SSH_TIMEOUT_SEC:-8}"
SSH_TRIES="${SIMAI_VM_SSH_TRIES:-3}"
SSH_RETRY_SLEEP_SEC="${SIMAI_VM_SSH_RETRY_SLEEP_SEC:-5}"
VM_SESSION_TIMEOUT_SEC="${SIMAI_VM_SESSION_TIMEOUT_SEC:-1800}"
VM_ENABLE_VMRUN_RECOVERY="${SIMAI_VM_ENABLE_VMRUN_RECOVERY:-0}"
VM_CONNECT_STATE_FILE="${SIMAI_VM_CONNECT_STATE_FILE:-${ROOT_DIR}/docs/.vm-connectivity.state}"
VM_CONNECT_COOLDOWN_BASE_SEC="${SIMAI_VM_CONNECT_COOLDOWN_BASE_SEC:-120}"
VM_CONNECT_COOLDOWN_MAX_SEC="${SIMAI_VM_CONNECT_COOLDOWN_MAX_SEC:-1800}"
VM_CONNECT_COOLDOWN_START_STREAK="${SIMAI_VM_CONNECT_COOLDOWN_START_STREAK:-3}"
VM_CONNECT_RESET_SEC="${SIMAI_VM_CONNECT_RESET_SEC:-21600}"
VM_DISK_GUARD_ENABLE="${SIMAI_VM_DISK_GUARD_ENABLE:-1}"
VM_DISK_MIN_FREE_GB="${SIMAI_VM_DISK_MIN_FREE_GB:-12}"
VM_DISK_PRUNE_KEEP="${SIMAI_VM_DISK_PRUNE_KEEP:-8}"

RET_BYTES="${SIMAI_BARRIER_TAIL_RETAIN_INFLIGHT_BYTES:-65536}"
RET_ACTIVE_THRESHOLD="${SIMAI_BARRIER_TAIL_ACTIVE_SRC_THRESHOLD:-8}"
RET_MIN_BYTES_LEFT="${SIMAI_BARRIER_TAIL_MIN_BYTES_LEFT:-1048576}"
RET_REQUIRE_COMPLETED="${SIMAI_BARRIER_TAIL_REQUIRE_COMPLETED_SOURCE:-0}"
RET_WORKLOAD="${SIMAI_WORKLOAD:-./example/microAllReduceLarge.txt}"
RET_TOPOLOGY="${SIMAI_TOPOLOGY:-./Spectrum-X_8g_8gps_400Gbps_H100}"
RET_CONFIG="${SIMAI_CONFIG:-astra-sim-alibabacloud/inputs/config/SimAI.vm.conf}"
RET_CASE_TIMEOUT="${SIMAI_CASE_TIMEOUT_SEC:-0}"
RET_CASE_TIMEOUT_CAP_ONLY="${SIMAI_CASE_TIMEOUT_SEC_CAP_ONLY:-${RET_CASE_TIMEOUT}}"
RET_CASE_TIMEOUT_CAP_PLUS_PRIO="${SIMAI_CASE_TIMEOUT_SEC_CAP_PLUS_PRIO:-${RET_CASE_TIMEOUT}}"
RET_THREADS="${SIMAI_THREADS:-16}"
RET_AS_LOG_LEVEL="${SIMAI_AS_LOG_LEVEL:-0}"
RET_WORKLOAD_STATE_TRACE="${SIMAI_WORKLOAD_STATE_TRACE:-}"
RET_WORKLOAD_STATE_TRACE_LIMIT="${SIMAI_WORKLOAD_STATE_TRACE_LIMIT:-}"
RET_WORKLOAD_STATE_TRACE_EVERY="${SIMAI_WORKLOAD_STATE_TRACE_EVERY:-}"
RET_COMPLETION_DIAG="${SIMAI_BARRIER_TAIL_COMPLETION_DIAG:-}"
RET_COMPLETION_DIAG_LAYER="${SIMAI_BARRIER_TAIL_COMPLETION_DIAG_LAYER:-}"
RET_COMPLETION_DIAG_LIMIT="${SIMAI_BARRIER_TAIL_COMPLETION_DIAG_LIMIT:-}"
RET_COMPLETION_DIAG_EVERY="${SIMAI_BARRIER_TAIL_COMPLETION_DIAG_EVERY:-}"
RET_STREAM_DIAG="${SIMAI_BARRIER_TAIL_STREAM_DIAG:-}"
RET_STREAM_DIAG_LIMIT="${SIMAI_BARRIER_TAIL_STREAM_DIAG_LIMIT:-}"
RET_STREAM_DIAG_EVERY="${SIMAI_BARRIER_TAIL_STREAM_DIAG_EVERY:-}"
RET_MERGE_DIAG="${SIMAI_MERGE_DIAG:-}"
RET_MERGE_DIAG_LAYER="${SIMAI_MERGE_DIAG_LAYER:-}"
RET_MERGE_DIAG_STRIDE="${SIMAI_MERGE_DIAG_STRIDE:-}"
RET_NUM_PASSES="${SIMAI_NUM_PASSES:-}"
RET_QP_DIAG="${SIMAI_BARRIER_TAIL_QP_DIAG:-}"
RET_SKIP_BUILD="${SIMAI_SKIP_BUILD:-0}"

LOG_PREFIX="[vm-autonomous-step]"
CONNECT_FAIL_STREAK=0
CONNECT_LAST_FAIL_EPOCH=0

if [[ -z "${VM_PASS}" ]]; then
  echo "${LOG_PREFIX} missing VM password (SIMAI_VM_PASS)" >&2
  exit 2
fi

load_connect_state() {
  CONNECT_FAIL_STREAK=0
  CONNECT_LAST_FAIL_EPOCH=0
  if [[ ! -f "${VM_CONNECT_STATE_FILE}" ]]; then
    return 0
  fi
  local value
  value="$(rg -n '^connect_fail_streak=' "${VM_CONNECT_STATE_FILE}" | tail -n 1 | cut -d'=' -f2 || true)"
  if [[ -n "${value}" && "${value}" =~ ^[0-9]+$ ]]; then
    CONNECT_FAIL_STREAK="${value}"
  fi
  value="$(rg -n '^connect_last_fail_epoch=' "${VM_CONNECT_STATE_FILE}" | tail -n 1 | cut -d'=' -f2 || true)"
  if [[ -n "${value}" && "${value}" =~ ^[0-9]+$ ]]; then
    CONNECT_LAST_FAIL_EPOCH="${value}"
  fi
}

save_connect_state() {
  local now_human
  now_human="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  {
    echo "connect_fail_streak=${CONNECT_FAIL_STREAK}"
    echo "connect_last_fail_epoch=${CONNECT_LAST_FAIL_EPOCH}"
    echo "updated_human=${now_human}"
  } > "${VM_CONNECT_STATE_FILE}"
}

reset_connect_state() {
  CONNECT_FAIL_STREAK=0
  CONNECT_LAST_FAIL_EPOCH=0
  save_connect_state
}

record_connectivity_failure() {
  local now_epoch
  now_epoch="$(date +%s)"
  if (( CONNECT_LAST_FAIL_EPOCH == 0 || now_epoch - CONNECT_LAST_FAIL_EPOCH > VM_CONNECT_RESET_SEC )); then
    CONNECT_FAIL_STREAK=1
  else
    CONNECT_FAIL_STREAK=$((CONNECT_FAIL_STREAK + 1))
  fi
  CONNECT_LAST_FAIL_EPOCH="${now_epoch}"
  save_connect_state
  echo "${LOG_PREFIX} recorded connectivity failure streak=${CONNECT_FAIL_STREAK}"
}

compute_connect_cooldown_sec() {
  local streak="$1"
  local cooldown="${VM_CONNECT_COOLDOWN_BASE_SEC}"
  local exponent=0
  local idx

  if (( streak < VM_CONNECT_COOLDOWN_START_STREAK )); then
    echo 0
    return 0
  fi

  exponent=$((streak - VM_CONNECT_COOLDOWN_START_STREAK))
  for ((idx = 0; idx < exponent; idx++)); do
    cooldown=$((cooldown * 2))
    if (( cooldown >= VM_CONNECT_COOLDOWN_MAX_SEC )); then
      cooldown="${VM_CONNECT_COOLDOWN_MAX_SEC}"
      break
    fi
  done

  if (( cooldown > VM_CONNECT_COOLDOWN_MAX_SEC )); then
    cooldown="${VM_CONNECT_COOLDOWN_MAX_SEC}"
  fi
  echo "${cooldown}"
}

cooldown_single_probe_mode() {
  local now_epoch
  now_epoch="$(date +%s)"

  if (( CONNECT_FAIL_STREAK < VM_CONNECT_COOLDOWN_START_STREAK )); then
    return 1
  fi
  if (( CONNECT_LAST_FAIL_EPOCH == 0 )); then
    return 1
  fi
  if (( now_epoch - CONNECT_LAST_FAIL_EPOCH > VM_CONNECT_RESET_SEC )); then
    return 1
  fi

  local cooldown_sec elapsed
  cooldown_sec="$(compute_connect_cooldown_sec "${CONNECT_FAIL_STREAK}")"
  if (( cooldown_sec <= 0 )); then
    return 1
  fi
  elapsed=$((now_epoch - CONNECT_LAST_FAIL_EPOCH))
  if (( elapsed >= cooldown_sec )); then
    return 1
  fi

  echo "${LOG_PREFIX} cooldown active (streak=${CONNECT_FAIL_STREAK} elapsed=${elapsed}s cooldown=${cooldown_sec}s); forcing single probe and skipping vmrun recovery"
  return 0
}

run_ssh_expect() {
  local remote_cmd="$1"
  expect /dev/stdin "${VM_HOST}" "${VM_USER}" "${VM_PASS}" "${SSH_CONNECT_TIMEOUT}" "${VM_SESSION_TIMEOUT_SEC}" "${remote_cmd}" <<'EOF'
set host [lindex $argv 0]
set user [lindex $argv 1]
set pass [lindex $argv 2]
set ctimeout [lindex $argv 3]
set stimeout [lindex $argv 4]
set rcmd [lindex $argv 5]

if {[string is integer -strict $stimeout] && $stimeout > 0} {
  set timeout $stimeout
} else {
  set timeout -1
}

spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password,publickey -o PubkeyAuthentication=no -o ConnectTimeout=$ctimeout $user@$host $rcmd
expect {
  -re ".*yes/no.*" {
    send "yes\r"
    exp_continue
  }
  -re ".*assword:.*" {
    send "$pass\r"
    exp_continue
  }
  timeout {
    send_user "expect_timeout: ssh session exceeded ${stimeout}s\n"
    catch {close}
    catch {exec kill -TERM [exp_pid]}
    after 1000
    catch {exec kill -KILL [exp_pid]}
    exit 124
  }
  eof
}
catch wait result
set ec [lindex $result 3]
exit $ec
EOF
}

try_vmrun_start() {
  if [[ ! -x "${VM_VMrun_BIN}" ]]; then
    echo "${LOG_PREFIX} vmrun not executable at ${VM_VMrun_BIN}" >&2
    return 1
  fi
  if [[ ! -f "${VM_VMX}" ]]; then
    echo "${LOG_PREFIX} vmx missing at ${VM_VMX}" >&2
    return 1
  fi
  echo "${LOG_PREFIX} attempting vmrun start ${VM_VMX}"
  "${VM_VMrun_BIN}" -T fusion start "${VM_VMX}" nogui || true
  sleep 5
  "${VM_VMrun_BIN}" -T fusion list || true
}

build_remote_cmd() {
  local remote_env=""
  if [[ -n "${RET_WORKLOAD_STATE_TRACE}" ]]; then
    remote_env+="export SIMAI_WORKLOAD_STATE_TRACE=\"${RET_WORKLOAD_STATE_TRACE}\""$'\n'
  fi
  if [[ -n "${RET_WORKLOAD_STATE_TRACE_LIMIT}" ]]; then
    remote_env+="export SIMAI_WORKLOAD_STATE_TRACE_LIMIT=\"${RET_WORKLOAD_STATE_TRACE_LIMIT}\""$'\n'
  fi
  if [[ -n "${RET_WORKLOAD_STATE_TRACE_EVERY}" ]]; then
    remote_env+="export SIMAI_WORKLOAD_STATE_TRACE_EVERY=\"${RET_WORKLOAD_STATE_TRACE_EVERY}\""$'\n'
  fi
  if [[ -n "${RET_COMPLETION_DIAG}" ]]; then
    remote_env+="export SIMAI_BARRIER_TAIL_COMPLETION_DIAG=\"${RET_COMPLETION_DIAG}\""$'\n'
  fi
  if [[ -n "${RET_COMPLETION_DIAG_LAYER}" ]]; then
    remote_env+="export SIMAI_BARRIER_TAIL_COMPLETION_DIAG_LAYER=\"${RET_COMPLETION_DIAG_LAYER}\""$'\n'
  fi
  if [[ -n "${RET_COMPLETION_DIAG_LIMIT}" ]]; then
    remote_env+="export SIMAI_BARRIER_TAIL_COMPLETION_DIAG_LIMIT=\"${RET_COMPLETION_DIAG_LIMIT}\""$'\n'
  fi
  if [[ -n "${RET_COMPLETION_DIAG_EVERY}" ]]; then
    remote_env+="export SIMAI_BARRIER_TAIL_COMPLETION_DIAG_EVERY=\"${RET_COMPLETION_DIAG_EVERY}\""$'\n'
  fi
  if [[ -n "${RET_STREAM_DIAG}" ]]; then
    remote_env+="export SIMAI_BARRIER_TAIL_STREAM_DIAG=\"${RET_STREAM_DIAG}\""$'\n'
  fi
  if [[ -n "${RET_STREAM_DIAG_LIMIT}" ]]; then
    remote_env+="export SIMAI_BARRIER_TAIL_STREAM_DIAG_LIMIT=\"${RET_STREAM_DIAG_LIMIT}\""$'\n'
  fi
  if [[ -n "${RET_STREAM_DIAG_EVERY}" ]]; then
    remote_env+="export SIMAI_BARRIER_TAIL_STREAM_DIAG_EVERY=\"${RET_STREAM_DIAG_EVERY}\""$'\n'
  fi
  if [[ -n "${RET_MERGE_DIAG}" ]]; then
    remote_env+="export SIMAI_MERGE_DIAG=\"${RET_MERGE_DIAG}\""$'\n'
  fi
  if [[ -n "${RET_MERGE_DIAG_LAYER}" ]]; then
    remote_env+="export SIMAI_MERGE_DIAG_LAYER=\"${RET_MERGE_DIAG_LAYER}\""$'\n'
  fi
  if [[ -n "${RET_MERGE_DIAG_STRIDE}" ]]; then
    remote_env+="export SIMAI_MERGE_DIAG_STRIDE=\"${RET_MERGE_DIAG_STRIDE}\""$'\n'
  fi
  if [[ -n "${RET_NUM_PASSES}" ]]; then
    remote_env+="export SIMAI_NUM_PASSES=\"${RET_NUM_PASSES}\""$'\n'
  fi
  if [[ -n "${RET_QP_DIAG}" ]]; then
    remote_env+="export SIMAI_BARRIER_TAIL_QP_DIAG=\"${RET_QP_DIAG}\""$'\n'
  fi
  cat <<EOF
set -euo pipefail
cd ${VM_WORKDIR}
echo "vm_pwd=\$(pwd)"
echo "vm_time=\$(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "vm_git_head=\$(git rev-parse --short HEAD 2>/dev/null || echo NA)"
${remote_env}
run_stamp=\$(date +%Y%m%d-%H%M%S)
run_log="/tmp/vm-autonomous-step-\${run_stamp}.log"
echo "run_log=\${run_log}"

if [[ "${VM_DISK_GUARD_ENABLE}" == "1" ]]; then
  disk_before_kb=\$(df -Pk "${VM_WORKDIR}" | awk 'NR==2 {print \$4}')
  disk_before_gb=\$((disk_before_kb / 1024 / 1024))
  echo "disk_guard_before_free_gb=\${disk_before_gb}"
  echo "disk_guard_min_free_gb=${VM_DISK_MIN_FREE_GB}"
  echo "disk_guard_prune_keep=${VM_DISK_PRUNE_KEEP}"
  if (( disk_before_gb < ${VM_DISK_MIN_FREE_GB} )); then
    results_dir="${VM_WORKDIR}/results"
    pruned_dirs=0
    if compgen -G "\${results_dir}/barrier-tail-retain-*" >/dev/null; then
      mapfile -t retain_dirs < <(ls -1dt "\${results_dir}"/barrier-tail-retain-* 2>/dev/null || true)
      total_dirs=\${#retain_dirs[@]}
      if (( total_dirs > ${VM_DISK_PRUNE_KEEP} )); then
        for ((idx = ${VM_DISK_PRUNE_KEEP}; idx < total_dirs; idx++)); do
          rm -rf "\${retain_dirs[\${idx}]}" || true
          pruned_dirs=\$((pruned_dirs + 1))
        done
      fi
    fi
    echo "disk_guard_pruned_dirs=\${pruned_dirs}"
  fi
  disk_after_kb=\$(df -Pk "${VM_WORKDIR}" | awk 'NR==2 {print \$4}')
  disk_after_gb=\$((disk_after_kb / 1024 / 1024))
  echo "disk_guard_after_free_gb=\${disk_after_gb}"
  if (( disk_after_gb < ${VM_DISK_MIN_FREE_GB} )); then
    echo "disk_guard_blocked=1"
    echo "disk_guard_reason=insufficient_free_space"
    exit 75
  fi
fi

(
  SIMAI_BARRIER_TAIL_RETAIN_INFLIGHT_BYTES=${RET_BYTES} \
  SIMAI_BARRIER_TAIL_ACTIVE_SRC_THRESHOLD=${RET_ACTIVE_THRESHOLD} \
  SIMAI_BARRIER_TAIL_MIN_BYTES_LEFT=${RET_MIN_BYTES_LEFT} \
  SIMAI_BARRIER_TAIL_REQUIRE_COMPLETED_SOURCE=${RET_REQUIRE_COMPLETED} \
  SIMAI_WORKLOAD=${RET_WORKLOAD} \
  SIMAI_TOPOLOGY=${RET_TOPOLOGY} \
  SIMAI_CONFIG=${RET_CONFIG} \
  SIMAI_CASE_TIMEOUT_SEC=${RET_CASE_TIMEOUT} \
  SIMAI_CASE_TIMEOUT_SEC_CAP_ONLY=${RET_CASE_TIMEOUT_CAP_ONLY} \
  SIMAI_CASE_TIMEOUT_SEC_CAP_PLUS_PRIO=${RET_CASE_TIMEOUT_CAP_PLUS_PRIO} \
  SIMAI_THREADS=${RET_THREADS} \
  SIMAI_AS_LOG_LEVEL=${RET_AS_LOG_LEVEL} \
  SIMAI_SKIP_BUILD=${RET_SKIP_BUILD} \
  ./scripts/run-barrier-tail-retain-diag.sh >"\${run_log}" 2>&1
) &
run_pid=\$!
while kill -0 "\${run_pid}" 2>/dev/null; do
  if [[ -f "\${run_log}" ]]; then
    log_bytes=\$(wc -c <"\${run_log}" 2>/dev/null || echo 0)
  else
    log_bytes=0
  fi
  echo "heartbeat: ts=\$(date '+%Y-%m-%d %H:%M:%S %Z') pid=\${run_pid} log_bytes=\${log_bytes}"
  sleep 60
done
run_rc=0
wait "\${run_pid}" || run_rc=\$?
if (( run_rc != 0 )); then
  echo "run_failed_rc=\${run_rc}"
  echo "run_log=\${run_log}"
  tail -n 120 "\${run_log}" || true
  exit "\${run_rc}"
fi
grep -E '^(root_dir=|out_dir=|retain_bytes=|active_src_threshold=|min_bytes_left=|require_completed_source=|workload=|as_log_level=|simai_threads=|case_timeout_sec_cap_only=|case_timeout_sec_cap_plus_prio=|rdma_hw_sha1=|qbb_net_device_sha1=|running cap_|stdout_log:|simai_log:|segmentation_fault:|group_key_source:|sendflow_lines:|barrier_flow_key_lines:|configured_group_modes:|unique_dst_flow_groups:|max_fanin_per_\(dst,flow_id\):|groups_with_fanin_gt_1:|barrier_tail_prio_enable:|barrier_tail_prio_disable:|barrier_tail_prio_total:|pass_finished:|all_passes_finished:|total_streams_injected:|total_streams_finished:|round_complete_markers:|round_complete_marker:|Candidate fan-in summary:|No candidate grouping produced fan-in > 1\.|  [A-Za-z0-9_:+-]+: unique_groups=[0-9]+ max_fanin=[0-9]+ groups_with_fanin_gt_1=[0-9]+|  trigger_events:|  trigger_bytes_left:|  trigger_active_sources:|  trigger_on_the_fly:|  local_select_events:|  local_competing_sendable:|  switch_enqueue_events:|  switch_egress_pg1_bytes:|  switch_egress_pg3_bytes:|  retain_block_events:|  retain_block_bytes_left:|  retain_block_on_the_fly:|  retain_block_caps:|analysis_failed:|case_exit_code:|case_timeout_sec:)' "\${run_log}" || true
EOF
}

main() {
  load_connect_state

  local effective_ssh_tries
  effective_ssh_tries="${SSH_TRIES}"
  local allow_vmrun_recovery
  allow_vmrun_recovery="${VM_ENABLE_VMRUN_RECOVERY}"
  if cooldown_single_probe_mode; then
    effective_ssh_tries=1
    allow_vmrun_recovery=0
  fi

  local remote_cmd
  remote_cmd="$(build_remote_cmd)"

  local i
  local last_connectivity_rc=0
  for ((i = 1; i <= effective_ssh_tries; i++)); do
    echo "${LOG_PREFIX} ssh attempt ${i}/${effective_ssh_tries} to ${VM_USER}@${VM_HOST}"
    local ssh_rc=0
    if run_ssh_expect "${remote_cmd}"; then
      ssh_rc=0
    else
      ssh_rc=$?
    fi
    if (( ssh_rc == 0 )); then
      reset_connect_state
      echo "${LOG_PREFIX} vm step succeeded"
      return 0
    fi

    echo "${LOG_PREFIX} ssh attempt ${i} failed (rc=${ssh_rc})"

    # Connection-level failures should retry. Remote command failures should
    # surface immediately so we do not loop long-running experiments.
    if (( ssh_rc != 255 && ssh_rc != 124 )); then
      echo "${LOG_PREFIX} remote command returned non-connectivity rc=${ssh_rc}; stop retrying"
      return "${ssh_rc}"
    fi
    last_connectivity_rc="${ssh_rc}"

    if (( i < effective_ssh_tries )); then
      if [[ "${allow_vmrun_recovery}" == "1" ]]; then
        try_vmrun_start || true
      else
        echo "${LOG_PREFIX} vmrun recovery disabled (SIMAI_VM_ENABLE_VMRUN_RECOVERY=${allow_vmrun_recovery})"
      fi
      sleep "${SSH_RETRY_SLEEP_SEC}"
    fi
  done

  if (( last_connectivity_rc == 255 || last_connectivity_rc == 124 )); then
    record_connectivity_failure
  fi
  echo "${LOG_PREFIX} all ssh attempts failed" >&2
  return 1
}

main "$@"
