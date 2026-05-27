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

if [[ -z "${VM_PASS}" ]]; then
  echo "${LOG_PREFIX} missing VM password (SIMAI_VM_PASS)" >&2
  exit 2
fi

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
  local remote_cmd
  remote_cmd="$(build_remote_cmd)"

  local i
  for ((i = 1; i <= SSH_TRIES; i++)); do
    echo "${LOG_PREFIX} ssh attempt ${i}/${SSH_TRIES} to ${VM_USER}@${VM_HOST}"
    local ssh_rc=0
    if run_ssh_expect "${remote_cmd}"; then
      ssh_rc=0
    else
      ssh_rc=$?
    fi
    if (( ssh_rc == 0 )); then
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

    if (( i < SSH_TRIES )); then
      try_vmrun_start || true
      sleep "${SSH_RETRY_SLEEP_SEC}"
    fi
  done

  echo "${LOG_PREFIX} all ssh attempts failed" >&2
  return 1
}

main "$@"
