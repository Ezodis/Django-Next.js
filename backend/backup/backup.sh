#!/bin/bash
# Portable backup/restore entry point shared across projects.
set -euo pipefail
cd "$(dirname "$0")/.."
export BACKUP_DIR="${BACKUP_DIR:-$PWD/backup}"
case "${1:-}" in
  backup|backup-daily|db|database)
    python -m config.backups create "$BACKUP_DIR" --scope db --project-tables ;;
  backup-db)
    python -m config.backups create "$BACKUP_DIR" --scope db ;;
  snapshot|snapshot-full|full)
    [[ "${FULL_BACKUP:-false}" == true ]] || { echo 'Set FULL_BACKUP=true for a full snapshot.'; exit 1; }
    python -m config.backups create "$BACKUP_DIR" --scope full ;;
  media|index)
    python -m config.backups create "$BACKUP_DIR" --scope "$1" ;;
  verify)
    python -m config.backups verify "${2:?Specify snapshot archive}" ;;
  restore)
    if [[ $# -eq 1 ]]; then
      python -m config.backups auto-restore
    else
      [[ -n "$2" ]] || { echo 'Specify a trusted snapshot archive to restore.'; exit 1; }
      python -m config.backups restore "$2" "${@:3}"
    fi ;;
  auto-restore)
    python -m config.backups auto-restore ;;
  list)
    find "$BACKUP_DIR" -maxdepth 2 -type f \( -name 'snapshot_*' -o -name 'backup_*' \) -print ;;
  reset)
    echo 'Startup recovery uses database state; deleting a marker never replaces an initialized database.' ;;
  *)
    echo 'Usage: backup.sh {backup|backup-db|snapshot|media|index|verify ARCHIVE|restore ARCHIVE|auto-restore|list}'
    exit 1 ;;
esac
