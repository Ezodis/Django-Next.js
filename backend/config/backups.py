"""Portable PostgreSQL/media archives; use from any host with project settings.

Archives contain data, never credentials. Only restore trusted archives into a
new database. Database and object storage cannot share one transaction: pause
uploads/deletes when an exact database/media boundary is required.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
from datetime import datetime, timezone
from urllib.parse import unquote, urlsplit, parse_qs
import uuid


def pg_environment():
    env = os.environ.copy()
    url = env.get('DATABASE_URL')
    if url:
        parsed = urlsplit(url)
        if parsed.scheme not in ('postgres', 'postgresql') or not parsed.hostname:
            raise ValueError('A PostgreSQL DATABASE_URL is required')
        env.update(PGHOST=parsed.hostname, PGPORT=str(parsed.port or 5432),
                   PGUSER=unquote(parsed.username or ''), PGPASSWORD=unquote(parsed.password or ''),
                   PGDATABASE=unquote(parsed.path.lstrip('/')))
        for key, value in parse_qs(parsed.query).items():
            if key in ('sslmode', 'sslrootcert', 'sslcert', 'sslkey', 'connect_timeout'):
                env['PG' + key.upper()] = value[-1]
    else:
        for pg, key, default in [('PGHOST', 'DB_HOST', 'localhost'), ('PGPORT', 'DB_PORT', '5432'),
                                 ('PGUSER', 'DB_USER', 'postgres'), ('PGPASSWORD', 'DB_PASSWORD', ''),
                                 ('PGDATABASE', 'DB_NAME', 'postgres')]:
            env[pg] = env.get(key, env.get(pg, default))
    return env


def run_pg(args, output=None):
    # Never put credentials in argv or surface SQL/data in exception messages.
    result = subprocess.run(args, env=pg_environment(), stdout=output or subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed (exit {result.returncode}); archive/restore was not completed')
    return result.stdout


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def safe_name(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name:
        raise ValueError('Unsafe archive/storage path')
    return path


def settings_and_storage():
    # Standalone exporters can supply a storage backend without loading the app
    # (useful for CI and recovery hosts without ML/application dependencies).
    if os.getenv('BACKUP_SOURCE_STORAGE'):
        from django.conf import settings
        from django.utils.module_loading import import_string
        if not settings.configured:
            settings.configure()
        config = json.loads(os.environ['BACKUP_SOURCE_STORAGE'])
        return settings, import_string(config['BACKEND'])(**config.get('OPTIONS', {}))
    import django
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')
    django.setup()
    from django.conf import settings
    from django.core.files.storage import default_storage
    return settings, default_storage


def storage_files(storage, prefix=''):
    from django.core.files.storage import FileSystemStorage
    if not prefix and isinstance(storage, FileSystemStorage) and not Path(storage.location).exists():
        return
    directories, files = storage.listdir(prefix)
    for name in sorted(files):
        yield str(safe_name('/'.join(filter(None, [prefix, name]))))
    for name in sorted(directories):
        yield from storage_files(storage, str(safe_name('/'.join(filter(None, [prefix, name])))))


def export_media(storage, root):
    root.mkdir()
    for name in storage_files(storage):
        target = root / safe_name(name)
        target.parent.mkdir(parents=True, exist_ok=True)
        with storage.open(name, 'rb') as source, target.open('wb') as dest:
            shutil.copyfileobj(source, dest, 1024 * 1024)


def create(destination, scope='full', storage=None, tables=None):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    token = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    name = 'snapshot_' + token + '.tar.gz'
    with tempfile.TemporaryDirectory(prefix='.backup-', dir=destination) as temporary:
        root = Path(temporary) / 'snapshot'
        root.mkdir()
        if scope in ('full', 'db', 'index'):
            command = ['pg_dump', '--no-owner', '--no-acl', '--encoding=UTF8']
            if tables is not None:
                if not tables:
                    raise ValueError('No project tables discovered; refusing an empty database backup')
                for table in tables:
                    command.extend(['--table', 'public.' + '"' + table.replace('"', '""') + '"'])
            with (root / 'database.sql').open('wb') as output:
                run_pg(command, output)
        if scope in ('full', 'media'):
            if storage is None:
                _, storage = settings_and_storage()
            export_media(storage, root / 'media')
        files = {p.relative_to(root).as_posix(): {'bytes': p.stat().st_size, 'sha256': digest(p)}
                 for p in sorted(root.rglob('*')) if p.is_file()}
        manifest = {'format': 1, 'created_at': datetime.now(timezone.utc).isoformat(),
                    'project': os.getenv('PROJECT_HOST') or os.getenv('BACKUP_PROJECT_ID', ''),
                    'scope': scope, 'database_format': 'postgresql-sql', 'files': files,
                    'consistency': 'Database is consistent; pause uploads/deletes for an exact media boundary.'}
        (root / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
        staged = Path(temporary) / name
        with tarfile.open(staged, 'w:gz') as archive:
            archive.add(root, arcname='snapshot', recursive=True)
        verify(staged)
        recipient = os.getenv('BACKUP_AGE_RECIPIENT')
        if recipient:
            encrypted = Path(temporary) / (name + '.age')
            subprocess.run(['age', '-r', recipient, '-o', str(encrypted), str(staged)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            staged = encrypted
        final = destination / staged.name
        os.replace(staged, final)
        checksum = digest(final)
        final.with_name(final.name + '.sha256').write_text(checksum + '  ' + final.name + '\n', encoding='ascii')
        publish(final)
        # Rotation only follows a fully successful local/offsite publication.
        retention = int(os.getenv('BACKUP_RETENTION', '7'))
        if retention < 1:
            raise ValueError('BACKUP_RETENTION must be positive')
        previous = sorted(destination.glob('snapshot_*.tar.gz*'), key=lambda p: p.name, reverse=True)
        previous = [p for p in previous if p.name.endswith(('.tar.gz', '.tar.gz.age'))]
        for old in previous[retention:]:
            old.unlink()
            old.with_name(old.name + '.sha256').unlink(missing_ok=True)
        return final


def publish(path):
    """Optional independent S3-compatible destination, with separate credentials."""
    copy_directory = os.getenv('BACKUP_COPY_DIRECTORY')
    if copy_directory:
        # An external drive or mounted personal/network drive uses the same files.
        destination = Path(copy_directory)
        destination.mkdir(parents=True, exist_ok=True)
        for artifact in (path, path.with_name(path.name + '.sha256')):
            staged = destination / (artifact.name + '.partial')
            shutil.copyfile(artifact, staged)
            if digest(staged) != digest(artifact):
                raise RuntimeError('Independent backup copy failed verification')
            os.replace(staged, destination / artifact.name)
    storage_config = os.getenv('BACKUP_DESTINATION_STORAGE')
    if storage_config:
        # Django storage adapters support S3, GCS and other installed providers.
        if not path.name.endswith('.age'):
            raise ValueError('Offsite uploads require encryption')
        from django.conf import settings
        from django.core.files import File
        from django.utils.module_loading import import_string
        if not settings.configured:
            settings.configure()
        config = json.loads(storage_config)
        storage = import_string(config['BACKEND'])(**config.get('OPTIONS', {}))
        prefix = os.environ['BACKUP_DESTINATION_PREFIX']
        safe_name(prefix)
        for artifact in (path, path.with_name(path.name + '.sha256')):
            key = prefix.strip('/') + '/' + artifact.name
            with artifact.open('rb') as source:
                if storage.save(key, File(source)) != key:
                    raise RuntimeError('Offsite backup object was unexpectedly renamed')
    bucket = os.getenv('BACKUP_S3_BUCKET')
    if not bucket:
        return
    if not path.name.endswith('.age'):
        raise ValueError('Offsite uploads require BACKUP_AGE_RECIPIENT encryption')
    import boto3
    client = boto3.client('s3', endpoint_url=os.getenv('BACKUP_S3_ENDPOINT_URL'),
                          region_name=os.getenv('BACKUP_S3_REGION', 'auto'),
                          aws_access_key_id=os.environ['BACKUP_S3_ACCESS_KEY_ID'],
                          aws_secret_access_key=os.environ['BACKUP_S3_SECRET_ACCESS_KEY'])
    prefix = os.getenv('BACKUP_S3_PREFIX') or os.getenv('PROJECT_HOST') or os.getenv('BACKUP_PROJECT_ID')
    if not prefix:
        raise ValueError('Offsite backups need a project-specific prefix')
    safe_name(prefix)
    for artifact in (path, path.with_name(path.name + '.sha256')):
        client.upload_file(str(artifact), bucket, prefix.strip('/') + '/' + artifact.name)


def extract(archive_path, target):
    """Validate every member before writing; reject links, devices and duplicates."""
    with tarfile.open(archive_path, 'r:gz') as archive:
        members = archive.getmembers()
        names = set()
        limit = int(os.getenv('BACKUP_MAX_EXPANDED_BYTES', str(100 * 1024**3)))
        total = 0
        for member in members:
            name = str(safe_name(member.name))
            if name in names or not (member.isfile() or member.isdir()):
                raise ValueError('Archive contains duplicate names or unsupported members')
            names.add(name)
            total += member.size
        if total > limit:
            raise ValueError('Archive exceeds BACKUP_MAX_EXPANDED_BYTES')
        archive.extractall(target, members=members, filter='data')
    roots = list(target.iterdir())
    if len(roots) != 1 or not roots[0].is_dir():
        raise ValueError('Snapshot must have exactly one root directory')
    return roots[0]


def verify_root(root, allow_legacy=False):
    manifest_path = root / 'manifest.json'
    if not manifest_path.exists():
        if allow_legacy and (root / 'database.sql').is_file():
            return {'scope': 'full', 'legacy': True}
        raise ValueError('Archive has no integrity manifest')
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if manifest.get('format') != 1 or manifest.get('scope') not in ('full', 'db', 'index', 'media'):
        raise ValueError('Unsupported snapshot format/scope')
    actual = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file() and p != manifest_path}
    if actual != set(manifest['files']):
        raise ValueError('Snapshot file inventory does not match manifest')
    for name, expected in manifest['files'].items():
        path = root / safe_name(name)
        if path.stat().st_size != expected['bytes'] or digest(path) != expected['sha256']:
            raise ValueError('Snapshot checksum mismatch')
    if manifest['scope'] in ('full', 'db', 'index') and not (root / 'database.sql').is_file():
        raise ValueError('Snapshot is missing its database')
    if manifest['scope'] in ('full', 'media') and not (root / 'media').is_dir():
        raise ValueError('Snapshot is missing its media directory')
    return manifest


def verify(path):
    with tempfile.TemporaryDirectory(prefix='backup-verify-') as temporary:
        return verify_root(extract(path, Path(temporary)))


def database_initialized():
    # Any user table prevents restore, including databases without migration history.
    value = run_pg(['psql', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c',
                    "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema'));"])
    return value.strip() == b't'


def project_tables():
    settings_and_storage()
    from django.apps import apps
    from django.db import connection
    from django.db.migrations.recorder import MigrationRecorder
    present = set(connection.introspection.table_names())
    owned = {model._meta.db_table for model in apps.get_models(include_auto_created=True)
             if model._meta.managed and not model._meta.proxy}
    owned.add(MigrationRecorder.Migration._meta.db_table)
    return sorted(owned & present)


def restore(path, allow_legacy=False):
    path = Path(path)
    with tempfile.TemporaryDirectory(prefix='backup-restore-') as temporary:
        target = Path(temporary)
        if path.name.endswith('.age'):
            decrypted = target / 'decrypted.tar.gz'
            subprocess.run(['age', '-d', '-i', os.environ['BACKUP_AGE_IDENTITY_FILE'],
                            '-o', str(decrypted), str(path)], check=True, stderr=subprocess.PIPE)
            path = decrypted
        extracted = target / 'contents'
        extracted.mkdir()
        if path.name.endswith('.tar.gz'):
            root = extract(path, extracted)
            manifest = verify_root(root, allow_legacy=allow_legacy)
            project = os.getenv('PROJECT_HOST') or os.getenv('BACKUP_PROJECT_ID', '')
            if project and manifest.get('project') and manifest['project'] != project:
                raise ValueError('Snapshot belongs to another project')
        else:
            if not allow_legacy:
                raise ValueError('Raw SQL requires explicit --allow-legacy')
            root = extracted
            if path.name.endswith('.sql.gz'):
                import gzip
                with gzip.open(path, 'rb') as source, (root / 'database.sql').open('wb') as output:
                    shutil.copyfileobj(source, output)
            elif path.suffix == '.sql':
                shutil.copyfile(path, root / 'database.sql')
            else:
                raise ValueError('Unsupported archive')
            manifest = {'scope': 'db'}
        sql = root / 'database.sql'
        if sql.exists() and database_initialized():
            raise ValueError('Restore requires an empty database; existing data was preserved')
        media = root / 'media'
        storage = None
        if media.exists():
            _, storage = settings_and_storage()
            # Refuse to overwrite uploaded objects; recovery uses a fresh destination.
            if next(storage_files(storage), None) is not None:
                raise ValueError('Restore requires empty media storage; existing uploads were preserved')
        if sql.exists():
            # Legacy dumps contain source ownership. Filter only those statements.
            clean = target / 'database.sql'
            with sql.open('rb') as source, clean.open('wb') as output:
                for line in source:
                    if not (line.startswith(b'ALTER ') and b' OWNER TO ' in line):
                        output.write(line)
            run_pg(['psql', '-X', '--single-transaction', '-v', 'ON_ERROR_STOP=1', '-f', str(clean)])
        if storage is not None:
            from django.core.files import File
            for source in sorted(media.rglob('*')):
                if source.is_file():
                    name = source.relative_to(media).as_posix()
                    with source.open('rb') as stream:
                        saved = storage.save(name, File(stream))
                    if saved != name:
                        raise RuntimeError('Storage renamed a restored object; recovery is incomplete')
        return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['create', 'verify', 'restore', 'auto-restore'])
    parser.add_argument('path', nargs='?')
    parser.add_argument('--scope', choices=['full', 'db', 'index', 'media'], default='full')
    parser.add_argument('--allow-legacy', action='store_true')
    parser.add_argument('--project-tables', action='store_true')
    args = parser.parse_args()
    backup_dir = Path(os.getenv('BACKUP_DIR', '/backend/backup'))
    if args.command == 'create':
        print(create(args.path or backup_dir, args.scope,
                     tables=project_tables() if args.project_tables else None))
    elif args.command == 'verify':
        print(json.dumps(verify(args.path), indent=2))
    elif args.command == 'restore':
        restore(args.path, args.allow_legacy)
        print('Restore completed. Apply project migrations before serving traffic.')
    else:
        start = backup_dir / 'start'
        candidates = sorted((p for p in start.glob('*') if p.name.endswith(('.tar.gz', '.tar.gz.age', '.sql.gz', '.sql'))),
                            key=lambda p: p.stat().st_mtime, reverse=True)
        if not candidates:
            print('No startup snapshot; preserving database.')
        elif database_initialized():
            print('Database already initialized; preserving data and skipping startup restore.')
        elif len(candidates) > 1:
            raise ValueError('Multiple startup snapshots: select exactly one to avoid ambiguous recovery')
        else:
            restore(candidates[0], allow_legacy=True)
            print('Startup snapshot restored successfully.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError, KeyError):
        # Fail closed; do not leak connection details or private data into logs.
        raise SystemExit('Backup/recovery failed. Source data was not intentionally replaced; check configuration and archive integrity.')
