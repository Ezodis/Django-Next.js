#!/bin/bash
# Google Cloud Storage Backup Utilities
# Handles GCS upload/download operations for backup files
# Separated from main backup.sh for modularity

set -e

# Configuration
BACKUP_DIR="/backend/backup"
START_DIR="${BACKUP_DIR}/start"
LOG_FILE="${BACKUP_DIR}/backup.log"
MAX_BACKUPS=7
MAX_SNAPSHOTS=5

# Paths
MEDIA_DIR="/backend/media"

# Environment detection (Django DEBUG setting)
IS_PRODUCTION="${DJANGO_DEBUG:-true}"
if [ "$IS_PRODUCTION" = "false" ] || [ "$IS_PRODUCTION" = "False" ]; then
    IS_PRODUCTION=true
else
    IS_PRODUCTION=false
fi

# GCS Configuration (hardcoded for production)
GCS_ENABLED="true"
GCS_BUCKET="3dy-backup"
GCS_PREFIX="backups/"
GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-}"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

# Error handling
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Create necessary directories
mkdir -p "${BACKUP_DIR}" "${START_DIR}"
touch "${LOG_FILE}"

# Upload to Google Cloud Storage (production only)
upload_to_gcs() {
    local file_path="$1"
    local file_name=$(basename "$file_path")
    local gcs_path="${2:-}"  # db/ or snapshots/ or empty for root
    
    if [ "$IS_PRODUCTION" != true ]; then
        log "Skipping GCS upload (not in production mode)"
        return 0
    fi
    
    if [ "$GCS_ENABLED" != "true" ]; then
        log "GCS upload disabled, skipping..."
        return 0
    fi
    
    if [ -z "$GCS_BUCKET" ]; then
        log "WARNING: GCS_BUCKET not set, cannot upload to GCS"
        return 1
    fi
    
    if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ] && [ -z "$GOOGLE_APPLICATION_CREDENTIALS_JSON" ]; then
        log "WARNING: Google credentials not found, cannot upload to GCS"
        return 1
    fi
    
    log "Uploading ${file_name} to GCS bucket ${GCS_BUCKET}..."
    
    # If credentials are provided as JSON string, write to temp file with secure permissions
    if [ -n "$GOOGLE_APPLICATION_CREDENTIALS_JSON" ]; then
        local temp_creds="/tmp/gcs_credentials_$.json"
        # Create file with restrictive permissions (only readable by owner)
        (umask 077 && echo "$GOOGLE_APPLICATION_CREDENTIALS_JSON" > "$temp_creds")
        export GOOGLE_APPLICATION_CREDENTIALS="$temp_creds"
    fi
    
    # Use Python with google-cloud-storage library
    # Pass variables via environment to avoid shell injection
    GCS_BUCKET_NAME="$GCS_BUCKET" \
    GCS_PREFIX_PATH="${GCS_PREFIX}${gcs_path}" \
    FILE_PATH="$file_path" \
    FILE_NAME="$file_name" \
    MAX_BACKUPS_COUNT="$MAX_BACKUPS" \
    python3 <<'EOF'
import os
from google.cloud import storage

try:
    # Read variables from environment
    bucket_name = os.environ['GCS_BUCKET_NAME']
    prefix = os.environ['GCS_PREFIX_PATH']
    file_path = os.environ['FILE_PATH']
    file_name = os.environ['FILE_NAME']
    max_backups = int(os.environ['MAX_BACKUPS_COUNT'])
    
    client = storage.Client()
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(f"{prefix}{file_name}")
    
    blob.upload_from_filename(file_path)
    
    print(f"✅ Uploaded {file_name} to gs://{bucket_name}/{prefix}{file_name}")
    
    # List all backups and delete old ones if needed
    blobs = list(bucket.list_blobs(prefix=prefix))
    backup_blobs = [b for b in blobs if b.name.startswith(f"{prefix}backup_") and b.name.endswith('.sql.gz')]
    
    if len(backup_blobs) > max_backups:
        # Sort by creation time
        backup_blobs.sort(key=lambda x: x.time_created)
        # Delete oldest backups
        for old_blob in backup_blobs[:len(backup_blobs) - max_backups]:
            old_blob.delete()
            print(f"🗑️  Deleted old backup: {old_blob.name}")
    
    exit(0)
except Exception as e:
    print(f"❌ Error uploading to GCS: {e}")
    exit(1)
EOF
    
    local upload_status=$?
    
    # Clean up temp credentials
    if [ -n "$GOOGLE_APPLICATION_CREDENTIALS_JSON" ]; then
        rm -f "$temp_creds"
    fi
    
    if [ $upload_status -eq 0 ]; then
        log "GCS upload completed successfully"
        return 0
    else
        log "WARNING: GCS upload failed"
        return 1
    fi
}

# Download from Google Cloud Storage
download_from_gcs() {
    local file_name="$1"
    local dest_path="$2"
    local gcs_path="${3:-}"  # db/ or snapshots/ or empty for root
    
    if [ "$GCS_ENABLED" != "true" ]; then
        log "GCS download disabled, skipping..."
        return 1
    fi
    
    if [ -z "$GCS_BUCKET" ]; then
        log "WARNING: GCS_BUCKET not set, cannot download from GCS"
        return 1
    fi
    
    log "Downloading ${file_name} from GCS bucket ${GCS_BUCKET}..."
    
    # If credentials are provided as JSON string, write to temp file with secure permissions
    if [ -n "$GOOGLE_APPLICATION_CREDENTIALS_JSON" ]; then
        local temp_creds="/tmp/gcs_credentials_$.json"
        # Create file with restrictive permissions (only readable by owner)
        (umask 077 && echo "$GOOGLE_APPLICATION_CREDENTIALS_JSON" > "$temp_creds")
        export GOOGLE_APPLICATION_CREDENTIALS="$temp_creds"
    fi
    
    # Use Python with google-cloud-storage library
    # Pass variables via environment to avoid shell injection
    GCS_BUCKET_NAME="$GCS_BUCKET" \
    GCS_PREFIX_PATH="${GCS_PREFIX}${gcs_path}" \
    FILE_NAME="$file_name" \
    DEST_PATH="$dest_path" \
    python3 <<'EOF'
import os
from google.cloud import storage

try:
    # Read variables from environment
    bucket_name = os.environ['GCS_BUCKET_NAME']
    prefix = os.environ['GCS_PREFIX_PATH']
    file_name = os.environ['FILE_NAME']
    dest_path = os.environ['DEST_PATH']
    
    client = storage.Client()
    bucket = client.bucket(bucket_name)
    
    if file_name == 'latest':
        # Get the most recent backup
        blobs = list(bucket.list_blobs(prefix=f"{prefix}backup_"))
        backup_blobs = [b for b in blobs if b.name.endswith('.sql.gz')]
        if not backup_blobs:
            print("❌ No backups found in GCS")
            exit(1)
        backup_blobs.sort(key=lambda x: x.time_created, reverse=True)
        blob = backup_blobs[0]
        print(f"📥 Downloading latest backup: {blob.name}")
    else:
        blob = bucket.blob(f"{prefix}{file_name}")
        if not blob.exists():
            print(f"❌ Backup {file_name} not found in GCS")
            exit(1)
    
    blob.download_to_filename(dest_path)
    print(f"✅ Downloaded to {dest_path}")
    exit(0)
except Exception as e:
    print(f"❌ Error downloading from GCS: {e}")
    exit(1)
EOF
    
    local download_status=$?
    
    # Clean up temp credentials
    if [ -n "$GOOGLE_APPLICATION_CREDENTIALS_JSON" ]; then
        rm -f "$temp_creds"
    fi
    
    return $download_status
}

# Sync media files to GCS using Django management command
sync_media_to_gcs() {
    log "=========================================="
    log "Syncing media files to GCS"
    log "=========================================="
    
    if [ "$IS_PRODUCTION" != true ]; then
        log "⚠️  Skipping GCS sync (not in production mode)"
        return 0
    fi
    
    # Check if Django is available
    if ! command -v python3 > /dev/null 2>&1; then
        log "⚠️  Python3 not found, cannot run Django management command"
        return 1
    fi
    
    log "Running Django management command: sync_media_to_gcs"
    
    # Use script directory to find backend root
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BACKEND_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
    
    cd "$BACKEND_DIR"
    python3 manage.py sync_media_to_gcs >> "${LOG_FILE}" 2>&1
    
    if [ $? -eq 0 ]; then
        log "✅ Media sync to GCS completed"
        return 0
    else
        log "⚠️  Media sync to GCS failed, check logs"
        return 1
    fi
}

# Upload backup file to GCS with automatic path detection
upload_backup_to_gcs() {
    local file_path="$1"
    local file_name=$(basename "$file_path")
    
    # Determine GCS path based on file type
    local gcs_path=""
    case "$file_name" in
        backup_*.sql.gz|*_backup.sql.gz)
            gcs_path="db/"
            ;;
        snapshot_*.tar.gz|*_snapshot.tar.gz)
            gcs_path="snapshots/"
            ;;
        *)
            gcs_path=""
            ;;
    esac
    
    log "Uploading ${file_name} to GCS path: ${GCS_PREFIX}${gcs_path}"
    upload_to_gcs "$file_path" "$gcs_path"
}

# Sync development data to production (upload dev backup for prod restore)
sync_dev_to_prod() {
    log "=== Syncing development data for production use ==="
    
    if [ "$GCS_ENABLED" != "true" ]; then
        log "ERROR: This operation requires GCS to be enabled"
        error_exit "Set GCS_ENABLED=true and configure GCS credentials"
    fi
    
    # Find the most recent local backup
    local latest_backup=$(ls -1t "${BACKUP_DIR}"/backup_*.sql.gz 2>/dev/null | head -n 1)
    
    if [ -z "$latest_backup" ]; then
        log "No local backups found. You need to create a backup first using:"
        log "  /backend/backup/backup.sh backup"
        error_exit "No backup files found to sync"
    fi
    
    log "Found latest backup: ${latest_backup}"
    
    # Upload to GCS with a special prefix for manual deployment
    local sync_filename="dev_to_prod_sync_$(date +%Y%m%d_%H%M%S).sql.gz"
    local sync_file="${BACKUP_DIR}/${sync_filename}"
    
    cp "$latest_backup" "$sync_file"
    
    log "Uploading development data to GCS as: ${sync_filename}"
    if upload_to_gcs "$sync_file" "dev_sync/"; then
        log "✅ Development data uploaded successfully!"
        log "To use this data in production:"
        log "1. Download the file from GCS: gs://${GCS_BUCKET}/${GCS_PREFIX}dev_sync/${sync_filename}"
        log "2. Place it in the /backend/backup/start/ directory as a .sql.gz file"
        log "3. Restart the production container"
        log ""
        log "Or download it directly:"
        log "  gsutil cp gs://${GCS_BUCKET}/${GCS_PREFIX}dev_sync/${sync_filename} /backend/backup/start/"
        rm -f "$sync_file"
        return 0
    else
        error_exit "Failed to upload development data to GCS"
    fi
}

# List GCS backups
list_gcs_backups() {
    log "=========================================="
    log "GCS Backups in ${GCS_BUCKET}"
    log "=========================================="
    
    if [ "$GCS_ENABLED" != "true" ]; then
        log "GCS is disabled"
        return 0
    fi
    
    # If credentials are provided as JSON string, write to temp file with secure permissions
    if [ -n "$GOOGLE_APPLICATION_CREDENTIALS_JSON" ]; then
        local temp_creds="/tmp/gcs_credentials_$.json"
        (umask 077 && echo "$GOOGLE_APPLICATION_CREDENTIALS_JSON" > "$temp_creds")
        export GOOGLE_APPLICATION_CREDENTIALS="$temp_creds"
    fi
    
    GCS_BUCKET_NAME="$GCS_BUCKET" \
    GCS_PREFIX_PATH="$GCS_PREFIX" \
    python3 <<'EOF'
import os
from google.cloud import storage
from datetime import datetime

try:
    bucket_name = os.environ['GCS_BUCKET_NAME']
    prefix = os.environ['GCS_PREFIX_PATH']
    
    client = storage.Client()
    bucket = client.bucket(bucket_name)
    
    print(f"\nDATABASE BACKUPS ({prefix}db/):")
    print("---")
    db_blobs = list(bucket.list_blobs(prefix=f"{prefix}db/"))
    if not db_blobs:
        print("  No database backups found")
    else:
        for blob in sorted(db_blobs, key=lambda x: x.time_created, reverse=True):
            size_mb = blob.size / (1024 * 1024)
            created = blob.time_created.strftime('%Y-%m-%d %H:%M:%S')
            print(f"  {blob.name.split('/')[-1]}")
            print(f"    Size: {size_mb:.1f}MB, Created: {created}")
    
    print(f"\nSNAPSHOTS ({prefix}snapshots/):")
    print("---")
    snapshot_blobs = list(bucket.list_blobs(prefix=f"{prefix}snapshots/"))
    if not snapshot_blobs:
        print("  No snapshots found")
    else:
        for blob in sorted(snapshot_blobs, key=lambda x: x.time_created, reverse=True):
            size_mb = blob.size / (1024 * 1024)
            created = blob.time_created.strftime('%Y-%m-%d %H:%M:%S')
            print(f"  {blob.name.split('/')[-1]}")
            print(f"    Size: {size_mb:.1f}MB, Created: {created}")
    
    print(f"\nDEV SYNC ({prefix}dev_sync/):")
    print("---")
    sync_blobs = list(bucket.list_blobs(prefix=f"{prefix}dev_sync/"))
    if not sync_blobs:
        print("  No dev sync files found")
    else:
        for blob in sorted(sync_blobs, key=lambda x: x.time_created, reverse=True):
            size_mb = blob.size / (1024 * 1024)
            created = blob.time_created.strftime('%Y-%m-%d %H:%M:%S')
            print(f"  {blob.name.split('/')[-1]}")
            print(f"    Size: {size_mb:.1f}MB, Created: {created}")
    
    exit(0)
except Exception as e:
    print(f"❌ Error listing GCS backups: {e}")
    exit(1)
EOF
    
    # Clean up temp credentials
    if [ -n "$GOOGLE_APPLICATION_CREDENTIALS_JSON" ]; then
        rm -f "$temp_creds"
    fi
    
    log "=========================================="
}

# Main execution
main() {
    case "${1:-}" in
        "upload")
            if [ -z "${2:-}" ]; then
                echo "Usage: $0 upload <file_path> [gcs_subpath]"
                echo "  file_path    - Local file to upload"
                echo "  gcs_subpath  - Optional GCS subdirectory (db/, snapshots/, etc.)"
                exit 1
            fi
            log "=== Upload to GCS ==="
            upload_to_gcs "$2" "${3:-}"
            ;;
        "upload-backup")
            if [ -z "${2:-}" ]; then
                echo "Usage: $0 upload-backup <backup_file>"
                echo "  Automatically detects backup type and uploads to correct GCS path"
                exit 1
            fi
            log "=== Upload Backup to GCS ==="
            upload_backup_to_gcs "$2"
            ;;
        "download")
            if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
                echo "Usage: $0 download <filename> <destination> [gcs_subpath]"
                echo "  filename     - File to download (or 'latest' for most recent backup)"
                echo "  destination  - Local destination path"
                echo "  gcs_subpath  - Optional GCS subdirectory (db/, snapshots/, etc.)"
                exit 1
            fi
            log "=== Download from GCS ==="
            download_from_gcs "$2" "$3" "${4:-}"
            ;;
        "sync-media")
            log "=== Sync Media to GCS ==="
            sync_media_to_gcs
            ;;
        "sync-dev-to-prod")
            log "=== Sync Development Data to Production ==="
            sync_dev_to_prod
            ;;
        "list")
            list_gcs_backups
            ;;
        *)
            echo "Google Cloud Storage Backup Utilities"
            echo "====================================="
            echo ""
            echo "Usage: $0 {upload|upload-backup|download|sync-media|sync-dev-to-prod|list}"
            echo ""
            echo "Commands:"
            echo "  upload <file> [path]     - Upload file to GCS with optional subpath"
            echo "  upload-backup <file>     - Upload backup file (auto-detects type and path)"
            echo "  download <file> <dest>   - Download file from GCS"
            echo "  sync-media               - Sync Django media files to GCS"
            echo "  sync-dev-to-prod         - Upload dev backup for production deployment"
            echo "  list                     - List all backups in GCS"
            echo ""
            echo "Examples:"
            echo "  $0 upload /path/to/backup.sql.gz db/"
            echo "  $0 upload-backup /backend/backup/backup_20240101_120000.sql.gz"
            echo "  $0 download latest /tmp/restore.sql.gz db/"
            echo "  $0 sync-dev-to-prod"
            echo "  $0 list"
            echo ""
            echo "Configuration:"
            echo "  GCS_BUCKET: ${GCS_BUCKET}"
            echo "  GCS_PREFIX: ${GCS_PREFIX}"
            echo "  GCS_ENABLED: ${GCS_ENABLED}"
            echo "  IS_PRODUCTION: ${IS_PRODUCTION}"
            exit 1
            ;;
    esac
}

main "$@"