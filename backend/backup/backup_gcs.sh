#!/bin/bash
# Compatibility entry point: destination adapters live in the shared exporter.
set -euo pipefail
[[ -n "${BACKUP_DESTINATION_STORAGE:-}" ]] || {
  echo 'Configure BACKUP_DESTINATION_STORAGE and BACKUP_DESTINATION_PREFIX before uploading.' >&2
  exit 1
}
[[ -n "${BACKUP_AGE_RECIPIENT:-}" ]] || {
  echo 'Configure the public BACKUP_AGE_RECIPIENT before uploading.' >&2
  exit 1
}
cd "$(dirname "$0")/.."
exec python -m config.backups create --scope full
