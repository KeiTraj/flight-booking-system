#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_ROOT="${ARCHIVE_DIR:-/wal_archive}"
COMPRESSED_DIR="${ARCHIVE_ROOT}/compressed"
RETENTION_HOURS="${ARCHIVE_RETENTION_HOURS:-168}"
POLL_INTERVAL="${ARCHIVE_POLL_INTERVAL:-600}"

mkdir -p "${COMPRESSED_DIR}"
echo "WAL archiver helper started. Watching ${ARCHIVE_ROOT} every ${POLL_INTERVAL}s (retention ${RETENTION_HOURS}h)."

compress_wal() {
  local wal_file="$1"
  local base_name
  base_name="$(basename "${wal_file}")"

  # Skip helper directories/files.
  [[ "${base_name}" == "compressed" ]] && return 0

  local target="${COMPRESSED_DIR}/${base_name}.gz"
  if [[ -f "${target}" ]]; then
    return 0
  fi

  if gzip -c "${wal_file}" > "${target}.tmp"; then
    mv "${target}.tmp" "${target}"
    touch -r "${wal_file}" "${target}"
    echo "Archived WAL ${base_name} -> compressed/${base_name}.gz"
  else
    echo "Failed to compress ${base_name}" >&2
    rm -f "${target}.tmp"
  fi
}

purge_old_archives() {
  local minutes=$(( RETENTION_HOURS * 60 ))
  find "${COMPRESSED_DIR}" -type f -mmin "+${minutes}" -print -delete 2>/dev/null || true
}

while true; do
  shopt -s nullglob
  for wal in "${ARCHIVE_ROOT}"/*; do
    [[ -f "${wal}" ]] || continue
    compress_wal "${wal}"
  done
  shopt -u nullglob
  purge_old_archives
  sleep "${POLL_INTERVAL}"
done
