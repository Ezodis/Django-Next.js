#!/bin/bash
# Unified PostgreSQL Backup and Restore Script
# Combines database backups, snapshots, and selective restore functionality
# Safe for shared databases - only affects current project tables

set -e

# Configuration
BACKUP_DIR="/backend/backup"
START_DIR="${BACKUP_DIR}/start"
LOG_FILE="${BACKUP_DIR}/backup.log"
RESTORE_MARKER="${BACKUP_DIR}/.db_restored"
MAX_BACKUPS=7
MEDIA_DIR="/backend/media"

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

# Parse DATABASE_URL if available (Railway/deployment)
parse_database_url() {
    if [ -n "$DATABASE_URL" ]; then
        log "Parsing DATABASE_URL..."
        
        DB_URL_NO_PROTO="${DATABASE_URL#postgres://}"
        DB_URL_NO_PROTO="${DB_URL_NO_PROTO#postgresql://}"
        
        DB_USER_PASS="${DB_URL_NO_PROTO%%@*}"
        export PGUSER="${DB_USER_PASS%%:*}"
        export PGPASSWORD="${DB_USER_PASS#*:}"
        
        DB_HOST_PORT_DB="${DB_URL_NO_PROTO#*@}"
        DB_HOST_PORT="${DB_HOST_PORT_DB%%/*}"
        export PGHOST="${DB_HOST_PORT%%:*}"
        if [ "$DB_HOST_PORT" = "$PGHOST" ]; then
            export PGPORT="5432"
        else
            export PGPORT="${DB_HOST_PORT#*:}"
        fi
        export PGDATABASE="${DB_HOST_PORT_DB#*/}"
        export PGDATABASE="${PGDATABASE%%\?*}"
    else
        export PGHOST="${DB_HOST:-localhost}"
        export PGPORT="${DB_PORT:-5432}"
        export PGDATABASE="${DB_NAME:-postgres}"
        export PGUSER="${DB_USER:-postgres}"
        export PGPASSWORD="${DB_PASSWORD:-postgres}"
    fi
}

# Wait for database to be ready
wait_for_database() {
    log "Waiting for database to be ready..."
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if pg_isready -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" > /dev/null 2>&1; then
            log "✅ Database is ready!"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    
    error_exit "Database not ready after ${max_attempts} attempts"
}

# Get tables belonging to current Django project
get_project_tables() {
    local project_tables=()
    
    # Always include Django core tables
    local core_tables=(
        "auth_group"
        "auth_group_permissions" 
        "auth_permission"
        "auth_user"
        "auth_user_groups"
        "auth_user_user_permissions"
        "authtoken_token"
        "django_admin_log"
        "django_content_type"
        "django_migrations"
        "django_session"
    )
    
    # Add core tables to project tables
    for table in "${core_tables[@]}"; do
        project_tables+=("$table")
    done
    
    # Get Django apps from current project
    if [ -f "/backend/manage.py" ]; then
        log "Detecting Django apps in current project..."
        
        # Get installed apps from Django
        local django_apps=$(cd /backend && python3 manage.py shell -c "
from django.conf import settings
from django.apps import apps
for app in apps.get_app_configs():
    if not app.name.startswith('django.') and not app.name.startswith('rest_framework'):
        print(app.label)
" 2>/dev/null || echo "")
        
        # For each Django app, get its tables
        if [ -n "$django_apps" ]; then
            echo "$django_apps" | while read -r app_name; do
                if [ -n "$app_name" ]; then
                    log "  Found app: $app_name"
                    # Get tables for this app (Django naming convention: appname_modelname)
                    local app_tables=$(psql -t -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE '${app_name}_%';" 2>/dev/null)
                    if [ -n "$app_tables" ]; then
                        echo "$app_tables" | while read -r table_name; do
                            table_name=$(echo "$table_name" | tr -d '[:space:]')
                            if [ -n "$table_name" ]; then
                                project_tables+=("$table_name")
                                log "    Table: $table_name"
                            fi
                        done
                    fi
                fi
            done
        fi
    fi
    
    # Also include any tables that match common patterns for this project
    local custom_tables=$(psql -t -c "
        SELECT table_name FROM information_schema.tables 
        WHERE table_schema = 'public' 
        AND table_name NOT LIKE 'auth_%' 
        AND table_name NOT LIKE 'django_%'
        AND table_name NOT LIKE 'authtoken_%'
        AND (
            table_name LIKE '%master'
            OR table_name LIKE '%book%'
            OR table_name LIKE '%order%'
        )
        ORDER BY table_name;
    " 2>/dev/null)
    
    if [ -n "$custom_tables" ]; then
        log "Found potential project tables:"
        echo "$custom_tables" | while read -r table_name; do
            table_name=$(echo "$table_name" | tr -d '[:space:]')
            if [ -n "$table_name" ]; then
                local row_count=$(psql -t -c "SELECT COUNT(*) FROM ${table_name};" 2>/dev/null | tr -d '[:space:]' || echo "0")
                project_tables+=("$table_name")
                log "  Including: $table_name ($row_count rows)"
            fi
        done
    fi
    
    # Return unique tables
    printf '%s\n' "${project_tables[@]}" | sort -u
}

# Perform database backup (selective or full)
perform_backup() {
    local backup_type="${1:-selective}"
    
    log "Starting ${backup_type} backup process..."
    
    # Parse database connection
    parse_database_url
    wait_for_database
    
    # Generate backup filename with timestamp
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/backup_${timestamp}.sql"
    local compressed_file="${backup_file}.gz"
    
    if [ "$backup_type" = "selective" ]; then
        # Selective backup (safe for shared databases)
        local project_tables=($(get_project_tables))
        
        if [ ${#project_tables[@]} -eq 0 ]; then
            log "⚠️  WARNING: No project tables detected"
            return 1
        fi
        
        log "📊 Detected ${#project_tables[@]} tables for current project"
        log "Creating SELECTIVE backup (current project tables only): ${backup_file}"
        
        # Create table arguments for pg_dump
        local table_args=""
        local included_count=0
        for table in "${project_tables[@]}"; do
            # Check if table exists before adding to backup
            local table_exists=$(psql -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '${table}';" 2>/dev/null | tr -d '[:space:]')
            if [ "$table_exists" = "1" ]; then
                table_args="${table_args} -t ${table}"
                log "  Including table: ${table}"
                included_count=$((included_count + 1))
            fi
        done
        
        if [ $included_count -eq 0 ]; then
            log "⚠️  WARNING: No project tables found to backup"
            return 1
        fi
        
        log "📊 Including ${included_count} tables in backup"
        
        # Create schema backup first
        local temp_schema_file="${backup_file}.schema"
        log "Creating table schemas..."
        
        pg_dump \
            --schema-only \
            --no-sync \
            ${table_args} \
            "${PGDATABASE}" > "${temp_schema_file}" 2>> "${LOG_FILE}"
        
        # Create data backup
        log "Creating data backup..."
        pg_dump \
            --data-only \
            --no-sync \
            ${table_args} \
            "${PGDATABASE}" > "${backup_file}" 2>> "${LOG_FILE}"
        
        # Combine schema and data
        cat "${temp_schema_file}" "${backup_file}" > "${backup_file}.combined"
        mv "${backup_file}.combined" "${backup_file}"
        rm -f "${temp_schema_file}"
        
        log "Selective backup created successfully"
        
    else
        # Full backup (traditional method)
        log "Creating FULL backup: ${backup_file}"
        
        # Show what will be backed up
        log "📊 Analyzing database before backup..."
        local total_tables=$(psql -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d '[:space:]')
        log "   Total tables in database: ${total_tables}"
        
        # Show key Django table counts (dynamic detection)
        log "📋 Key table contents:"
        
        # Always show Django core tables if they exist
        for table_name in "auth_user" "django_migrations"; do
            local count=$(psql -t -c "SELECT COUNT(*) FROM ${table_name};" 2>/dev/null | tr -d '[:space:]' || echo "N/A")
            if [ "$count" != "N/A" ] && [ "$count" != "0" ]; then
                log "   📚 ${table_name}: ${count} records"
            elif [ "$count" = "0" ]; then
                log "   📭 ${table_name}: empty"
            fi
        done
        
        # Show app-specific tables (non-Django core tables with data)
        local app_tables=$(psql -t -c "
            SELECT table_name, 
                   (xpath('/row/c/text()', query_to_xml('SELECT COUNT(*) as c FROM ' || table_name, false, true, '')))[1]::text::int as row_count
            FROM information_schema.tables 
            WHERE table_schema = 'public' 
            AND table_name NOT LIKE 'auth_%' 
            AND table_name NOT LIKE 'django_%'
            AND table_name NOT LIKE 'authtoken_%'
            ORDER BY table_name;
        " 2>/dev/null)
        
        if [ -n "$app_tables" ]; then
            echo "$app_tables" | while IFS='|' read -r table_name row_count; do
                table_name=$(echo "$table_name" | tr -d '[:space:]')
                row_count=$(echo "$row_count" | tr -d '[:space:]')
                if [ -n "$table_name" ] && [ "$row_count" -gt 0 ] 2>/dev/null; then
                    log "   📚 ${table_name}: ${row_count} records"
                elif [ -n "$table_name" ] && [ "$row_count" = "0" ] 2>/dev/null; then
                    log "   📭 ${table_name}: empty"
                fi
            done
        fi
        
        # Show all non-empty tables
        log "📊 All non-empty tables being backed up:"
        psql -t -c "
            SELECT 
                schemaname||'.'||tablename as table_name,
                n_tup_ins - n_tup_del as estimated_rows
            FROM pg_stat_user_tables 
            WHERE schemaname = 'public' 
            AND (n_tup_ins - n_tup_del) > 0
            ORDER BY (n_tup_ins - n_tup_del) DESC;
        " 2>/dev/null | while read -r line; do
            if [ -n "$line" ]; then
                table_info=$(echo "$line" | tr -d '[:space:]' | tr '|' ' ')
                if [ -n "$table_info" ]; then
                    log "   📋 $table_info"
                fi
            fi
        done
        
        log "🔄 Starting pg_dump..."
        if pg_dump \
            --clean \
            --if-exists \
            --encoding=UTF8 \
            --verbose \
            --no-sync \
            "${PGDATABASE}" > "${backup_file}" 2>> "${LOG_FILE}"; then
            
            log "✅ Full backup created successfully"
            
            # Verify backup content
            local backup_size=$(du -h "${backup_file}" | cut -f1)
            local backup_lines=$(wc -l < "${backup_file}")
            log "📊 Backup verification:"
            log "   📄 File size: ${backup_size}"
            log "   📝 Total lines: ${backup_lines}"
            
            # Check if main data is in backup (dynamic detection)
            local main_data_in_backup=$(grep -c "COPY public\." "${backup_file}" | grep -v "auth_\|django_\|authtoken_" || echo "0")
            if [ "$main_data_in_backup" -gt 0 ]; then
                # Find the largest table in backup
                local largest_backup_table=$(grep "COPY public\." "${backup_file}" | grep -v "auth_\|django_\|authtoken_" | head -1 | sed 's/.*COPY public\.\([^ ]*\).*/\1/')
                if [ -n "$largest_backup_table" ]; then
                    local main_data_lines=$(sed -n "/COPY public\.${largest_backup_table}/,/^\\\./p" "${backup_file}" | wc -l)
                    local actual_records=$((main_data_lines - 2))  # subtract header and terminator
                    log "   📚 Main data in backup (${largest_backup_table}): ${actual_records} records"
                fi
            else
                log "   📭 No main data tables found in backup"
            fi
            
        else
            error_exit "Failed to create full backup"
        fi
    fi
    
    # Compress backup
    log "Compressing backup..."
    if gzip -f "${backup_file}"; then
        log "Backup compressed: ${compressed_file}"
        
        # Rotate backups
        local backup_count=$(ls -1 "${BACKUP_DIR}"/backup_*.sql.gz 2>/dev/null | wc -l)
        if [ "$backup_count" -gt "$MAX_BACKUPS" ]; then
            ls -1t "${BACKUP_DIR}"/backup_*.sql.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f
            log "Removed old backups, kept last ${MAX_BACKUPS}"
        fi
        
        log "✅ ${backup_type^} backup completed successfully"
        if [ "$backup_type" = "selective" ]; then
            log "📊 Backup contains only current project tables, safe for shared database"
        fi
        return 0
    else
        error_exit "Failed to compress backup"
    fi
}

# Create full snapshot (database + media)
create_snapshot() {
    log "=========================================="
    log "Creating FULL SNAPSHOT (database + media)"
    log "=========================================="
    
    parse_database_url
    wait_for_database
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local version="v${timestamp}"
    local snapshot_name="snapshot_${version}"
    local temp_dir="${BACKUP_DIR}/temp_${timestamp}"
    local snapshot_file="${BACKUP_DIR}/${snapshot_name}.tar.gz"
    
    mkdir -p -m 755 "${temp_dir}"
    
    # 1. Database backup
    log "Step 1/3: Backing up database..."
    local db_file="${temp_dir}/database.sql"
    local pg_dump_errors=$(mktemp)
    
    if pg_dump \
        --clean \
        --if-exists \
        --encoding=UTF8 \
        --verbose \
        "${PGDATABASE}" > "${db_file}" 2> "${pg_dump_errors}"; then
        log "✅ Database backed up successfully"
        log "   Size: $(du -h "${db_file}" | cut -f1)"
        rm -f "${pg_dump_errors}"
    else
        local exit_code=$?
        log "❌ ERROR: Database backup failed (exit code: ${exit_code})"
        if [ -s "${pg_dump_errors}" ]; then
            log "Errors encountered:"
            while IFS= read -r error_line; do
                log "  ${error_line}"
            done < "${pg_dump_errors}"
            cat "${pg_dump_errors}" >> "${LOG_FILE}"
        fi
        rm -f "${pg_dump_errors}"
        rm -rf "${temp_dir}"
        error_exit "Failed to backup database"
    fi
    
    # 2. Media files backup
    log "Step 2/3: Backing up media files..."
    
    if [ -d "${MEDIA_DIR}" ]; then
        local media_backup_dir="${temp_dir}/media"
        mkdir -p "${media_backup_dir}"
        
        local file_count=$(find "${MEDIA_DIR}" -type f 2>/dev/null | wc -l)
        log "Found ${file_count} files in media directory"
        
        if [ "$file_count" -gt 0 ]; then
            local cpio_errors=$(mktemp)
            if (cd "${MEDIA_DIR}" && find . -mindepth 1 -print0 | cpio -p0dum "${media_backup_dir}/" 2> "${cpio_errors}"); then
                log "✅ Media files backed up successfully"
                log "   Files: ${file_count}"
                log "   Size: $(du -sh "${media_backup_dir}" | cut -f1)"
                rm -f "${cpio_errors}"
            else
                local exit_code=$?
                log "⚠️  WARNING: Media backup completed with errors (exit code: ${exit_code})"
                if [ -s "${cpio_errors}" ]; then
                    log "Errors encountered:"
                    while IFS= read -r error_line; do
                        log "  ${error_line}"
                    done < "${cpio_errors}"
                    cat "${cpio_errors}" >> "${LOG_FILE}"
                fi
                rm -f "${cpio_errors}"
                
                local backed_up_count=$(find "${media_backup_dir}" -type f 2>/dev/null | wc -l)
                log "Files backed up: ${backed_up_count} of ${file_count}"
                log "   Size: $(du -sh "${media_backup_dir}" | cut -f1)"
            fi
        else
            log "ℹ️  No media files to backup"
        fi
    else
        log "ℹ️  Media directory not found"
    fi
    
    # 3. Create metadata
    log "Step 3/3: Creating snapshot metadata..."
    
    cat > "${temp_dir}/snapshot_info.txt" <<EOF
Full Snapshot - ${version}
========================
Created: $(date '+%Y-%m-%d %H:%M:%S')
Version: ${version}

Contents:
- database.sql: PostgreSQL database dump
- media/: Django media files

Database Info:
- Host: ${PGHOST}
- Port: ${PGPORT}
- Database: ${PGDATABASE}

Restore Instructions:
1. Extract this archive
2. Restore database: psql -h \$DB_HOST -U \$DB_USER -d \$DB_NAME < database.sql
3. Restore media: cp -r media/* /backend/media/
EOF
    
    log "✅ Metadata created"
    
    # 4. Create compressed archive
    log "Creating compressed snapshot archive..."
    
    if tar -czf "${snapshot_file}" -C "${BACKUP_DIR}" "temp_${timestamp}" 2>> "${LOG_FILE}"; then
        log "✅ Snapshot created successfully"
        log "   Location: ${snapshot_file}"
        log "   Size: $(du -h "${snapshot_file}" | cut -f1)"
        log "   Version: ${version}"
    else
        rm -rf "${temp_dir}"
        error_exit "Failed to create snapshot archive"
    fi
    
    # Cleanup
    rm -rf "${temp_dir}"
    
    # Rotate old snapshots
    local snapshot_count=$(ls -1 "${BACKUP_DIR}"/snapshot_*.tar.gz 2>/dev/null | wc -l)
    if [ "$snapshot_count" -gt "$MAX_BACKUPS" ]; then
        ls -1t "${BACKUP_DIR}"/snapshot_*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f
        log "✅ Rotated old snapshots (kept last ${MAX_BACKUPS})"
    fi
    
    log "=========================================="
    log "✅ FULL SNAPSHOT COMPLETED"
    log "=========================================="
    
    return 0
}

# Show database statistics
show_database_stats() {
    local table_count=$(psql -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$table_count" ] && [ "$table_count" -gt 0 ]; then
        log "📊 Database restored with ${table_count} tables"
        
        # Show main data count (dynamic detection)
        local largest_table=$(psql -t -c "
            SELECT table_name
            FROM information_schema.tables t
            JOIN (
                SELECT schemaname, tablename, n_tup_ins - n_tup_del as estimated_rows
                FROM pg_stat_user_tables 
                WHERE schemaname = 'public'
                AND tablename NOT LIKE 'auth_%' 
                AND tablename NOT LIKE 'django_%'
                AND tablename NOT LIKE 'authtoken_%'
            ) s ON t.table_name = s.tablename
            WHERE t.table_schema = 'public'
            ORDER BY s.estimated_rows DESC
            LIMIT 1;
        " 2>/dev/null | tr -d '[:space:]')
        
        if [ -n "$largest_table" ]; then
            local main_count=$(psql -t -c "SELECT COUNT(*) FROM ${largest_table};" 2>/dev/null | tr -d '[:space:]' || echo "N/A")
            if [ "$main_count" != "N/A" ] && [ "$main_count" != "0" ]; then
                log "📚 Main data in database (${largest_table}): ${main_count}"
            else
                log "📚 Main data in database: No data found in ${largest_table} table"
            fi
        else
            log "📚 Main data in database: No main data table found"
        fi
        
        # Try to show other common tables
        local users_count=$(psql -t -c "SELECT COUNT(*) FROM auth_user;" 2>/dev/null | tr -d '[:space:]' || echo "N/A")
        if [ "$users_count" != "N/A" ]; then
            log "👥 Users in database: ${users_count}"
        fi
    fi
}

# Restore from database file (.sql or .sql.gz)
restore_database_file() {
    local db_file="$1"
    log "=========================================="
    log "Restoring from DATABASE: $(basename "$db_file")"
    log "=========================================="
    
    # Decompress if needed
    local sql_file="$db_file"
    if [[ "$db_file" == *.gz ]]; then
        log "Decompressing database file..."
        sql_file="${db_file%.gz}"
        if gunzip -c "$db_file" > "$sql_file"; then
            log "✅ File decompressed to: $sql_file"
            
            # Quick validation of SQL file
            local file_size=$(stat -c%s "$sql_file" 2>/dev/null || echo "0")
            log "SQL file size: ${file_size} bytes"
            
            if [ "$file_size" -lt 1000 ]; then
                log "⚠️  WARNING: SQL file seems too small (${file_size} bytes)"
                log "First few lines of SQL file:"
                head -n 5 "$sql_file" | while IFS= read -r line; do
                    log "  $line"
                done
            else
                # Show what tables are being restored
                log "Debug: Tables being restored from backup:"
                grep -i "CREATE TABLE" "$sql_file" | head -10 | while IFS= read -r line; do
                    log "  $line"
                done
                
                # Check for main data in backup (dynamic detection)
                local main_data_copy_lines=$(grep -i "COPY.*\|INSERT INTO.*" "$sql_file" | grep -v "auth_\|django_\|authtoken_" | wc -l)
                log "Debug: Main data lines in backup: ${main_data_copy_lines}"
                
                # Count actual records in backup for largest table
                if [ "$main_data_copy_lines" -gt 0 ]; then
                    # Find the largest COPY statement in backup
                    local largest_copy=$(grep -i "COPY public\." "$sql_file" | grep -v "auth_\|django_\|authtoken_" | head -1)
                    if [ -n "$largest_copy" ]; then
                        local table_name=$(echo "$largest_copy" | sed 's/.*COPY public\.\([^ ]*\).*/\1/')
                        local actual_record_count=$(sed -n "/COPY public\.${table_name}/,/^\\\./p" "$sql_file" | wc -l)
                        if [ "$actual_record_count" -gt 2 ]; then
                            local records=$((actual_record_count - 2))  # subtract header and terminator
                            log "Debug: Actual records in backup (${table_name}): ${records}"
                        fi
                    fi
                fi
            fi
        else
            log "ERROR: Failed to decompress database file"
            return 1
        fi
    fi
    
    # Check current database state
    local table_count=$(psql -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d '[:space:]')
    local non_django_tables=$(psql -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name NOT LIKE 'auth_%' AND table_name NOT LIKE 'django_%' AND table_name NOT LIKE 'authtoken_%';" 2>/dev/null | tr -d '[:space:]')
    
    if [ "$non_django_tables" -gt 0 ]; then
        log "⚠️  WARNING: Database contains ${non_django_tables} tables from other projects!"
        log "This appears to be a shared database."
        
        # Get current project's Django apps
        local current_project_tables=""
        if [ -f "/backend/manage.py" ]; then
            current_project_tables=$(cd /backend && python3 manage.py shell -c "
from django.apps import apps
for app in apps.get_app_configs():
    if not app.name.startswith('django.') and not app.name.startswith('rest_framework'):
        for model in app.get_models():
            print(model._meta.db_table)
" 2>/dev/null || echo "")
        fi
        
        # List the foreign tables (excluding current project tables)
        log "Non-current project tables found:"
        local exclude_condition="table_name NOT LIKE 'auth_%' AND table_name NOT LIKE 'django_%' AND table_name NOT LIKE 'authtoken_%'"
        
        # Add current project tables to exclusion
        if [ -n "$current_project_tables" ]; then
            echo "$current_project_tables" | while read -r project_table; do
                if [ -n "$project_table" ]; then
                    exclude_condition="${exclude_condition} AND table_name != '${project_table}'"
                fi
            done
        fi
        
        psql -t -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND ${exclude_condition} ORDER BY table_name;" 2>/dev/null | head -10 | while read -r table_name; do
            if [ -n "$table_name" ]; then
                log "  - ${table_name}"
            fi
        done
        
        log "💡 Proceeding with full restore - all project tables will be restored"
    fi
    
    # Check for data in current project's main tables (dynamic detection)
    local main_data_count="0"
    local main_table=""
    
    # Get the largest non-Django table (likely the main data table)
    local largest_table=$(psql -t -c "
        SELECT table_name
        FROM information_schema.tables t
        JOIN (
            SELECT schemaname, tablename, n_tup_ins - n_tup_del as estimated_rows
            FROM pg_stat_user_tables 
            WHERE schemaname = 'public'
            AND tablename NOT LIKE 'auth_%' 
            AND tablename NOT LIKE 'django_%'
            AND tablename NOT LIKE 'authtoken_%'
        ) s ON t.table_name = s.tablename
        WHERE t.table_schema = 'public'
        ORDER BY s.estimated_rows DESC
        LIMIT 1;
    " 2>/dev/null | tr -d '[:space:]')
    
    if [ -n "$largest_table" ]; then
        main_data_count=$(psql -t -c "SELECT COUNT(*) FROM ${largest_table};" 2>/dev/null | tr -d '[:space:]' || echo "0")
        if [ "$main_data_count" != "0" ]; then
            main_table="$largest_table"
            log "Current state - Tables: ${table_count:-0}, Main data (${largest_table}): ${main_data_count}"
        else
            log "Current state - Tables: ${table_count:-0}, Main data: 0 (${largest_table} table empty)"
        fi
    else
        log "Current state - Tables: ${table_count:-0}, Main data: 0 (no main data table found)"
    fi
    
    if [ -n "$table_count" ] && [ "$table_count" -gt 0 ]; then
        log "🔄 Database has existing data - will be replaced with backup data"
    else
        log "📦 Database is empty - restoring from backup"
    fi
    
    # Force restore with CASCADE to handle foreign key constraints
    local psql_errors=$(mktemp)
    log "Executing restore with CASCADE to handle constraints..."
    
    if psql --single-transaction -f "${sql_file}" > /dev/null 2> "${psql_errors}"; then
        log "✅ Database restored successfully from $(basename "$db_file")"
        rm -f "${psql_errors}"
        
        # Create marker file to prevent future restores
        echo "Database restored on $(date) from $(basename "$db_file")" > "$RESTORE_MARKER"
        log "✅ Restore marker created: $RESTORE_MARKER"
        
        # Clean up restore files to save space
        log "Cleaning up restore files..."
        rm -f "$db_file"
        if [ "$sql_file" != "$db_file" ]; then
            rm -f "$sql_file"
        fi
        log "✅ Restore files cleaned up"
        
        # Show final stats
        show_database_stats
        
        log "=========================================="
        log "✅ DATABASE RESTORE COMPLETED"
        log "=========================================="
        
        return 0
    else
        local exit_code=$?
        log "⚠️  WARNING: Database restore failed (exit code: ${exit_code})"
        
        # Log detailed error information
        if [ -s "${psql_errors}" ]; then
            log "Detailed errors:"
            while IFS= read -r error_line; do
                log "  ERROR: ${error_line}"
            done < "${psql_errors}"
            cat "${psql_errors}" >> "${LOG_FILE}"
        fi
        rm -f "${psql_errors}"
        
        # Try alternative restore method without ON_ERROR_STOP
        log "Attempting alternative restore method..."
        local psql_errors2=$(mktemp)
        if psql -f "${sql_file}" > /dev/null 2> "${psql_errors2}"; then
            log "✅ Alternative restore method succeeded"
            rm -f "${psql_errors2}"
            
            # Create marker and cleanup
            echo "Database restored on $(date) from $(basename "$db_file") (alternative method)" > "$RESTORE_MARKER"
            rm -f "$db_file"
            if [ "$sql_file" != "$db_file" ]; then
                rm -f "$sql_file"
            fi
            
            show_database_stats
            return 0
        else
            log "❌ Alternative restore method also failed"
            if [ -s "${psql_errors2}" ]; then
                log "Alternative method errors:"
                while IFS= read -r error_line; do
                    log "  ERROR: ${error_line}"
                done < "${psql_errors2}"
            fi
            rm -f "${psql_errors2}"
        fi
        
        # Check PostgreSQL versions for debugging
        log "PostgreSQL client version: $(psql --version 2>/dev/null || echo 'Unknown')"
        log "Database server version: $(psql -t -c 'SELECT version();' 2>/dev/null | head -n1 | tr -d '[:space:]' || echo 'Unknown')"
        
        log "Container will continue startup..."
        # Don't create marker on failure, allow retry
        return 1
    fi
}

# Restore from snapshot file (.tar.gz)
restore_snapshot_file() {
    local snapshot_file="$1"
    log "=========================================="
    log "Restoring from SNAPSHOT: $(basename "$snapshot_file")"
    log "=========================================="
    
    local temp_restore_dir="${BACKUP_DIR}/restore_temp_$$"
    mkdir -p -m 755 "${temp_restore_dir}"
    
    # Extract archive
    log "Extracting snapshot..."
    if tar -xzf "${snapshot_file}" -C "${temp_restore_dir}" 2>> "${LOG_FILE}"; then
        log "✅ Archive extracted"
    else
        rm -rf "${temp_restore_dir}"
        log "ERROR: Failed to extract snapshot"
        return 1
    fi
    
    local extracted_dir=$(find "${temp_restore_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    
    if [ -z "$extracted_dir" ]; then
        rm -rf "${temp_restore_dir}"
        log "ERROR: Could not find extracted directory"
        return 1
    fi
    
    # Show snapshot info if available
    if [ -f "${extracted_dir}/snapshot_info.txt" ]; then
        log "Snapshot Information:"
        cat "${extracted_dir}/snapshot_info.txt" | tee -a "${LOG_FILE}"
        log "----------------------------------------"
    fi
    
    # Restore database
    log "Restoring database from snapshot..."
    if [ -f "${extracted_dir}/database.sql" ]; then
        local psql_errors=$(mktemp)
        if psql --single-transaction -f "${extracted_dir}/database.sql" > /dev/null 2> "${psql_errors}"; then
            log "✅ Database restored successfully"
            rm -f "${psql_errors}"
        else
            local exit_code=$?
            log "⚠️  WARNING: Database restore failed (exit code: ${exit_code})"
            if [ -s "${psql_errors}" ]; then
                log "Errors encountered:"
                while IFS= read -r error_line; do
                    log "  ${error_line}"
                done < "${psql_errors}"
                cat "${psql_errors}" >> "${LOG_FILE}"
            fi
            rm -f "${psql_errors}"
        fi
    else
        log "⚠️  No database.sql file found in snapshot"
    fi
    
    # Restore media files
    log "Restoring media files from snapshot..."
    if [ -d "${extracted_dir}/media" ]; then
        mkdir -p "${MEDIA_DIR}"
        
        local file_count=$(find "${extracted_dir}/media" -type f 2>/dev/null | wc -l)
        log "Found ${file_count} media files to restore"
        
        if [ "$file_count" -gt 0 ]; then
            local cpio_errors=$(mktemp)
            if (cd "${extracted_dir}/media" && find . -mindepth 1 -print0 | cpio -p0dum "${MEDIA_DIR}/" 2> "${cpio_errors}"); then
                log "✅ Media files restored successfully"
                rm -f "${cpio_errors}"
            else
                log "⚠️  WARNING: Media restore completed with errors"
                if [ -s "${cpio_errors}" ]; then
                    cat "${cpio_errors}" >> "${LOG_FILE}"
                fi
                rm -f "${cpio_errors}"
            fi
        fi
    else
        log "ℹ️  No media files in snapshot"
    fi
    
    # Cleanup
    rm -rf "${temp_restore_dir}"
    
    # Create marker and cleanup
    echo "Snapshot restored on $(date) from $(basename "$snapshot_file")" > "$RESTORE_MARKER"
    log "✅ Restore marker created: $RESTORE_MARKER"
    
    # Clean up snapshot file
    rm -f "$snapshot_file"
    log "✅ Snapshot file cleaned up"
    
    # Show stats
    show_database_stats
    
    log "=========================================="
    log "✅ SNAPSHOT RESTORE COMPLETED"
    log "=========================================="
    
    return 0
}

# Auto-restore from start directory
auto_restore() {
    log "Checking for restore files in ${START_DIR}..."
    
    # Check if already restored (prevent loops)
    if [ -f "$RESTORE_MARKER" ]; then
        log "ℹ️  Database already restored (marker file exists)"
        log "   Marker: $RESTORE_MARKER"
        log "   To force restore, delete the marker file and restart"
        return 0
    fi
    
    # Parse database connection
    parse_database_url
    wait_for_database
    
    # Debug: List all files in start directory
    log "Debug: Contents of start directory:"
    if ls -la "${START_DIR}/" >> "${LOG_FILE}" 2>&1; then
        ls -la "${START_DIR}/" | while read -r line; do
            log "  $line"
        done
    else
        log "  Error: Cannot list start directory contents"
    fi
    
    # Look for files in priority order:
    # 1. Snapshot files (.tar.gz) - full backups with media
    # 2. Database files (.sql.gz) - database only
    # 3. Uncompressed SQL files (.sql)
    local restore_file=""
    local restore_type=""
    
    # Check for snapshot files first
    restore_file=$(ls -1t "${START_DIR}"/*.tar.gz 2>/dev/null | head -n 1)
    if [ -n "$restore_file" ]; then
        restore_type="snapshot"
        log "Found snapshot file: ${restore_file}"
    else
        # Check for compressed SQL files
        restore_file=$(ls -1t "${START_DIR}"/*.sql.gz 2>/dev/null | head -n 1)
        if [ -n "$restore_file" ]; then
            restore_type="database"
            log "Found database backup: ${restore_file}"
        else
            # Check for uncompressed SQL files
            restore_file=$(ls -1t "${START_DIR}"/*.sql 2>/dev/null | head -n 1)
            if [ -n "$restore_file" ]; then
                restore_type="database"
                log "Found uncompressed database backup: ${restore_file}"
            fi
        fi
    fi
    
    if [ -z "$restore_file" ]; then
        log "No restore files found in ${START_DIR}, skipping restore"
        return 0
    fi
    
    # Handle different restore types
    case "$restore_type" in
        "snapshot")
            restore_snapshot_file "$restore_file"
            ;;
        "database")
            restore_database_file "$restore_file"
            ;;
        *)
            log "ERROR: Unknown restore type"
            return 1
            ;;
    esac
}

# Reset restore marker
reset_restore() {
    if [ -f "$RESTORE_MARKER" ]; then
        rm -f "$RESTORE_MARKER"
        log "✅ Restore marker removed: $RESTORE_MARKER"
        log "   Next startup will restore database again"
    else
        log "ℹ️  No restore marker found"
    fi
}

# List backups and status
list_backups() {
    log "=========================================="
    log "Available Backups"
    log "=========================================="
    
    log ""
    log "DATABASE BACKUPS (${BACKUP_DIR}):"
    log "---"
    local db_backups=$(ls -1t "${BACKUP_DIR}"/backup_*.sql.gz 2>/dev/null || true)
    if [ -z "$db_backups" ]; then
        log "  No database backups found"
    else
        echo "$db_backups" | while read -r backup; do
            local size=$(du -h "$backup" | cut -f1)
            local date=$(stat -c %y "$backup" 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1)
            log "  $(basename "$backup")"
            log "    Size: ${size}, Date: ${date}"
        done
    fi
    
    log ""
    log "SNAPSHOTS (${BACKUP_DIR}):"
    log "---"
    local snapshots=$(ls -1t "${BACKUP_DIR}"/snapshot_*.tar.gz 2>/dev/null || true)
    if [ -z "$snapshots" ]; then
        log "  No snapshots found"
    else
        echo "$snapshots" | while read -r snapshot; do
            local size=$(du -h "$snapshot" | cut -f1)
            local date=$(stat -c %y "$snapshot" 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1)
            log "  $(basename "$snapshot")"
            log "    Size: ${size}, Date: ${date}"
        done
    fi
    
    log ""
    log "START DIRECTORY (${START_DIR}):"
    log "---"
    local start_files=$(ls -1t "${START_DIR}"/*.{tar.gz,sql.gz,sql} 2>/dev/null || true)
    if [ -z "$start_files" ]; then
        log "  No restore files found"
    else
        echo "$start_files" | while read -r file; do
            local size=$(du -h "$file" | cut -f1)
            local date=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1)
            local type="Unknown"
            case "$file" in
                *.tar.gz) type="Snapshot (DB + Media)" ;;
                *.sql.gz) type="Database (Compressed)" ;;
                *.sql) type="Database (Uncompressed)" ;;
            esac
            log "  $(basename "$file") [${type}]"
            log "    Size: ${size}, Date: ${date}"
        done
    fi
    
    log ""
    log "RESTORE STATUS:"
    log "---"
    if [ -f "$RESTORE_MARKER" ]; then
        local marker_date=$(cat "$RESTORE_MARKER" 2>/dev/null || echo "Unknown date")
        log "  ✅ Database restored: ${marker_date}"
    else
        log "  ⏳ Database not yet restored (will restore on next startup)"
    fi
    
    log "=========================================="
}

# Main execution
main() {
    case "${1:-}" in
        "backup")
            log "=== Database Backup ==="
            perform_backup "selective"
            ;;
        "backup-db")
            log "=== Full Database Backup ==="
            perform_backup "full"
            ;;
        "backup-daily"|"db"|"database")
            log "=== Daily Database Backup ==="
            perform_backup "selective"
            ;;
        "snapshot")
            if [ "${FULL_BACKUP:-false}" != "true" ]; then
                log "⚠️  FULL_BACKUP environment variable not set to 'true'"
                log "   Set FULL_BACKUP=true to proceed with snapshot creation"
                exit 1
            fi
            log "=== Full Snapshot Creation ==="
            create_snapshot
            ;;
        "snapshot-full"|"full")
            if [ "${FULL_BACKUP:-false}" != "true" ]; then
                log "⚠️  FULL_BACKUP environment variable not set to 'true'"
                log "   Set FULL_BACKUP=true to proceed with snapshot creation"
                exit 1
            fi
            log "=== Full Snapshot Creation ==="
            create_snapshot
            ;;
        "restore")
            log "=== Manual Restore ==="
            auto_restore
            ;;
        "auto-restore")
            log "=== Auto-Restore on Startup ==="
            if auto_restore; then
                log "Auto-restore completed successfully or no files to restore"
            else
                log "WARNING: Auto-restore failed but container will continue startup"
                log "Check ${LOG_FILE} for error details"
            fi
            # Always return success for auto-restore to not block container startup
            return 0
            ;;
        "reset")
            log "=== Reset Restore Marker ==="
            reset_restore
            ;;
        "list")
            list_backups
            ;;
        *)
            echo "Unified PostgreSQL Backup and Restore Script"
            echo "============================================"
            echo ""
            echo "Usage: $0 {backup|backup-db|backup-daily|snapshot|snapshot-full|restore|auto-restore|reset|list}"
            echo ""
            echo "Commands:"
            echo "  backup       - Create selective database backup (safe for shared DB)"
            echo "  backup-db    - Create full database backup (traditional method)"
            echo "  backup-daily - Create daily database backup (same as backup)"
            echo "  db           - Alias for backup-daily"
            echo "  database     - Alias for backup-daily"
            echo "  snapshot     - Create full snapshot (DB + media) - requires FULL_BACKUP=true"
            echo "  snapshot-full- Alias for snapshot"
            echo "  full         - Alias for snapshot"
            echo "  restore      - Restore from start directory"
            echo "  auto-restore - Auto-restore on startup (non-failing, one-time)"
            echo "  reset        - Reset restore marker (allows re-restore)"
            echo "  list         - List all backups and restore status"
            echo ""
            echo "Examples:"
            echo "  $0 backup"
            echo "  $0 backup-db"
            echo "  $0 db"
            echo "  FULL_BACKUP=true $0 snapshot"
            echo "  FULL_BACKUP=true $0 full"
            echo "  $0 restore"
            echo "  $0 reset"
            echo "  $0 list"
            echo ""
            echo "Workflow for deployment:"
            echo "  1. Create backup: $0 backup"
            echo "  2. Copy to start: cp backup_*.sql.gz start/"
            echo "     OR copy snapshot: cp snapshot_*.tar.gz start/"
            echo "  3. Deploy - automatic one-time restore"
            echo "  4. Add more data incrementally (no restore loop)"
            echo ""
            echo "Supported file types in start directory:"
            echo "  *.tar.gz  - Full snapshots (database + media)"
            echo "  *.sql.gz  - Compressed database backups"
            echo "  *.sql     - Uncompressed database backups"
            echo ""
            echo "Files:"
            echo "  Backups:      ${BACKUP_DIR}/"
            echo "  Restore from: ${START_DIR}/"
            echo "  Marker:       ${RESTORE_MARKER}"
            exit 1
            ;;
    esac
}

main "$@"