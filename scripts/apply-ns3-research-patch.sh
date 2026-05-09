#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
ROOT_DIR="${SCRIPT_DIR}/.."
PATCH_FILE="${ROOT_DIR}/patches/ns3-barrier-tail-priority.patch"
TARGET_DIR="${ROOT_DIR}/ns-3-alibabacloud"

if [ ! -f "${PATCH_FILE}" ]; then
  echo "Patch file not found: ${PATCH_FILE}" >&2
  exit 1
fi

if [ ! -d "${TARGET_DIR}/.git" ] && [ ! -f "${TARGET_DIR}/.git" ]; then
  echo "Target ns-3 repository not found: ${TARGET_DIR}" >&2
  exit 1
fi

if git -C "${TARGET_DIR}" apply --check "${PATCH_FILE}" >/dev/null 2>&1; then
  git -C "${TARGET_DIR}" apply "${PATCH_FILE}"
  echo "Applied patch: ${PATCH_FILE}"
  exit 0
fi

if grep -q "m_tail_critical" "${TARGET_DIR}/simulation/src/point-to-point/model/rdma-queue-pair.h" \
  && grep -q "GroupId" "${TARGET_DIR}/simulation/src/applications/model/rdma-client.cc"; then
  echo "Patch already applied: ${PATCH_FILE}"
  exit 0
fi

echo "Patch could not be applied cleanly: ${PATCH_FILE}" >&2
exit 1
