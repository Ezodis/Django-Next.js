#!/bin/sh
set -e

echo "🚀 Starting Django development container"

# Parse DATABASE_URL to extract connection parameters
if [ -n "$DATABASE_URL" ]; then
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

# Wait for database
echo "⏳ Waiting for database..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if pg_isready -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" > /dev/null 2>&1; then
        echo "✅ Database ready"
        break
    fi
    attempt=$((attempt + 1))
    echo "   attempt ${attempt}/${max_attempts}..."
    sleep 2
done
if [ $attempt -eq $max_attempts ]; then
    echo "❌ Database not ready after ${max_attempts} attempts — exiting"
    exit 1
fi

# Auto-restore from backup if present
if [ -f /backend/backup/backup.sh ]; then
    # The backup utility owns restore eligibility and its completion marker.
    /backend/backup/backup.sh auto-restore || true
fi

if [ -f manage.py ]; then
    echo "📦 Applying migrations..."
    python manage.py migrate --noinput || { echo "❌ Migration failed"; exit 1; }
    echo "✅ Migrations done"

    echo "📁 Collecting static files..."
    python manage.py collectstatic --noinput --clear 2>/dev/null || true

    # Create superuser
    if [ -n "$DJANGO_SUPERUSER_USERNAME" ] && [ -n "$DJANGO_SUPERUSER_PASSWORD" ] && [ -n "$DOMAIN" ]; then
        python manage.py shell << END
import os
from django.contrib.auth import get_user_model
User = get_user_model()
username = os.getenv('DJANGO_SUPERUSER_USERNAME')
domain = os.getenv('DOMAIN')
email = f'{username}@{domain}'
if not User.objects.filter(username=username).exists():
    User.objects.create_superuser(username, email, os.getenv('DJANGO_SUPERUSER_PASSWORD'))
    print(f"✅ Superuser created: {username}")
else:
    print(f"✅ Superuser exists: {username}")
END
    fi

    # Run app entrypoint hooks in background.
    # Any installed app can provide a `manage.py entrypoint` command — Django discovers it automatically.
    echo "🔧 Running app entrypoint hooks in background..."
    (python manage.py entrypoint >> /tmp/entrypoint_hooks.log 2>&1) &
fi

exec "$@"
