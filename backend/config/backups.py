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
from contextlib import contextmanager
import base64
import re
from urllib.request import Request, urlopen
from urllib.error import HTTPError


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


def run_pg(args, output=None, environment=None):
    # Never put credentials in argv or surface SQL/data in exception messages.
    result = subprocess.run(args, env=environment or pg_environment(), stdout=output or subprocess.PIPE,
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


def identity_file():
    identity = Path(os.getenv('BACKUP_AGE_IDENTITY_FILE') or Path.home() / '.config/project-backups/identity.txt')
    if not identity.is_file():
        raise ValueError('Recovery requires the private age identity outside Git')
    return identity


@contextmanager
def plaintext_archive(path):
    path = Path(path)
    if path.name.endswith('.age'):
        with tempfile.TemporaryDirectory(prefix='backup-decrypt-') as temporary:
            decrypted = Path(temporary) / 'snapshot.tar.gz'
            subprocess.run(['age', '-d', '-i', str(identity_file()), '-o', str(decrypted), str(path)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            yield decrypted
    else:
        yield path


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


class GitHubBackupError(RuntimeError):
    def __init__(self, status):
        self.status = status
        super().__init__(f'GitHub backup request failed (HTTP {status})')


def github_client(root):
    """Use the current checkout and existing CLI login; never store a token."""
    result = subprocess.run(['git', '-C', str(root), 'config', '--get', 'remote.origin.url'],
                            capture_output=True, text=True, check=True)
    remote = result.stdout.strip().removesuffix('.git')
    match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([\w.-]+/[\w.-]+)', remote)
    if not match:
        raise ValueError('Backup upload requires this checkout to have a GitHub origin')
    repository = match[1]
    command = shutil.which('gh') or shutil.which('gh.exe')
    if not command:
        # The Windows launcher runs Linux containers; reuse its Windows CLI login.
        powershell = shutil.which('powershell.exe') or '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
        if Path(powershell).is_file():
            resolved = subprocess.run([powershell, '-NoProfile', '-NonInteractive', '-Command',
                                      '(Get-Command gh -ErrorAction Stop).Source'], capture_output=True, text=True)
            if resolved.returncode == 0:
                command = subprocess.check_output(['wslpath', '-u', resolved.stdout.strip()], text=True).strip()
    if not command:
        raise ValueError('Install GitHub CLI and sign in with gh auth login before uploading')
    login = subprocess.run([command, 'auth', 'token', '--hostname', 'github.com'], capture_output=True, text=True)
    if login.returncode or not login.stdout.strip():
        raise ValueError('Sign in to GitHub CLI before uploading a backup')
    token = login.stdout.strip()

    def api(endpoint, data=None, method=None):
        request = Request(f'https://api.github.com/repos/{repository}/{endpoint}',
                          data=json.dumps(data).encode() if data is not None else None,
                          method=method, headers={'Authorization': 'Bearer ' + token,
                          'Accept': 'application/vnd.github+json', 'Content-Type': 'application/json'})
        try:
            with urlopen(request, timeout=60) as response:
                return json.load(response)
        except HTTPError as error:
            raise GitHubBackupError(error.code) from None
    return repository, api


def backup_tree(api):
    try:
        head = api('git/ref/heads/production-backups')['object']['sha']
    except GitHubBackupError as error:
        if error.status == 404:
            return None, None, []
        raise
    tree = api('git/commits/' + head)['tree']['sha']
    listing = api('git/trees/' + tree + '?recursive=1')
    if listing.get('truncated'):
        raise ValueError('Backup tree is too large; use independent object storage')
    return head, tree, listing['tree']


def github_upload(path, root, api=None, recipient=None):
    """Publish encrypted local data without switching branches or changing files."""
    path, root = Path(path).resolve(), Path(root).resolve()
    if not path.name.startswith('snapshot_') or not path.name.endswith(('.tar.gz', '.tar.gz.age')):
        raise ValueError('Choose a portable snapshot created by the backup command')
    manifest = verify(path)
    try:
        from .project_config import environment_values
    except ImportError:
        from project_config import environment_values
    values = environment_values(root)
    expected = values.get('PROJECT_HOST') or root.name.lower()
    if not manifest.get('project') or manifest['project'] != expected:
        raise ValueError('Local snapshot belongs to another project or has no project identity')
    repository, api = github_client(root) if api is None else ('test/repository', api)
    if not path.name.endswith('.age'):
        recipient = recipient or values.get('BACKUP_AGE_RECIPIENT') or api('actions/variables/BACKUP_AGE_RECIPIENT')['value']
        encrypted = path.with_name(path.name + '.age')
        with tempfile.TemporaryDirectory(prefix='.backup-upload-', dir=path.parent) as temporary:
            staged = Path(temporary) / encrypted.name
            subprocess.run(['age', '-r', recipient, '-o', str(staged), str(path)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            os.replace(staged, encrypted)
        path = encrypted
    if path.stat().st_size >= 90 * 1024**2:
        raise ValueError('GitHub snapshot exceeds 90 MiB; use independent object storage')
    with path.open('rb') as stream:
        encrypted_header = stream.read(22)
    if not encrypted_header.startswith(b'age-encryption.org/v1\n'):
        raise ValueError('GitHub uploads require a valid age-encrypted snapshot')
    checksum = path.with_name(path.name + '.sha256')
    checksum.write_text(digest(path) + '  ' + path.name + '\n', encoding='ascii')
    # The recovery branch contains data rather than an application. Disable
    # deploy hooks in the configured web root before publishing its next commit.
    deployment_guard = b'{"git":{"deploymentEnabled":false}}\n'
    guard_blob = api('git/blobs', {'content': base64.b64encode(deployment_guard).decode('ascii'),
                                 'encoding': 'base64'})['sha']
    updates = [{'path': 'frontend/web/vercel.json', 'mode': '100644',
                'type': 'blob', 'sha': guard_blob}]
    for artifact in (path, checksum):
        content = artifact.read_bytes()
        blob = api('git/blobs', {'content': base64.b64encode(content).decode('ascii'), 'encoding': 'base64'})['sha']
        expected_blob = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()
        if blob != expected_blob:
            raise RuntimeError('GitHub upload failed integrity verification')
        updates.append({'path': 'snapshots/local/' + artifact.name, 'mode': '100644', 'type': 'blob', 'sha': blob})
    for attempt in range(3):
        head, tree, existing = backup_tree(api)
        names = {entry['path'] for entry in existing if entry['path'].startswith('snapshots/local/snapshot_')
                 and entry['path'].endswith('.tar.gz.age')}
        names.add('snapshots/local/' + path.name)
        deletions = [{'path': name + suffix, 'mode': '100644', 'type': 'blob', 'sha': None}
                     for name in sorted(names, reverse=True)[7:] for suffix in ('', '.sha256')
                     if any(entry['path'] == name + suffix for entry in existing)]
        payload = {'tree': updates + deletions}
        if tree:
            payload['base_tree'] = tree
        new_tree = api('git/trees', payload)['sha']
        commit = api('git/commits', {'message': 'Store encrypted local snapshot', 'tree': new_tree,
                                   'parents': [head] if head else []})['sha']
        try:
            if head:
                api('git/refs/heads/production-backups', {'sha': commit, 'force': False}, method='PATCH')
            else:
                api('git/refs', {'ref': 'refs/heads/production-backups', 'sha': commit})
            return f'https://github.com/{repository}/tree/production-backups/snapshots/local'
        except GitHubBackupError as error:
            if error.status not in (409, 422) or attempt == 2:
                raise
    raise RuntimeError('Concurrent backup uploads prevented publication; local snapshot was preserved')


def github_download(destination, root, source='local', api=None):
    """Download a chosen backup source; verification and restore remain explicit."""
    if source not in ('local', 'production'):
        raise ValueError('Choose local or production backups')
    _, api = github_client(root) if api is None else ('test/repository', api)
    _, _, tree = backup_tree(api)
    prefix = 'snapshots/local/' if source == 'local' else 'snapshots/'
    candidates = [entry for entry in tree if entry['type'] == 'blob' and entry['path'].startswith(prefix)
                  and '/' not in entry['path'][len(prefix):] and entry['path'][len(prefix):].startswith('snapshot_')
                  and entry['path'].endswith('.tar.gz.age')]
    if not candidates:
        raise ValueError('No snapshot available for the selected source')
    entry = max(candidates, key=lambda item: item['path'])
    safe_name(entry['path'])
    if entry.get('size', 0) >= 90 * 1024**2:
        raise ValueError('Remote snapshot exceeds the GitHub backup size limit')
    checksum_entry = next((item for item in tree if item['path'] == entry['path'] + '.sha256'), None)
    if not checksum_entry:
        raise ValueError('Remote snapshot has no integrity checksum')
    checksum = base64.b64decode(api('git/blobs/' + checksum_entry['sha'])['content'])
    content = base64.b64decode(api('git/blobs/' + entry['sha'])['content'])
    parts = checksum.decode('ascii').split()
    if len(content) >= 90 * 1024**2 or not parts or not re.fullmatch(r'[0-9a-f]{64}', parts[0]):
        raise ValueError('Remote snapshot has an invalid size or checksum')
    if not content.startswith(b'age-encryption.org/v1\n') or hashlib.sha256(content).hexdigest() != parts[0]:
        raise ValueError('Remote snapshot checksum mismatch')
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    final = destination / Path(entry['path']).name
    with tempfile.TemporaryDirectory(prefix='.backup-download-', dir=destination) as temporary:
        staged = Path(temporary) / final.name
        staged.write_bytes(content)
        os.replace(staged, final)
    final.with_name(final.name + '.sha256').write_bytes(checksum)
    with plaintext_archive(final) as decrypted:
        manifest = verify(decrypted)
        try:
            from .project_config import environment_values
        except ImportError:
            from project_config import environment_values
        if manifest.get('project') != (environment_values(root).get('PROJECT_HOST') or Path(root).name.lower()):
            raise ValueError('Downloaded snapshot belongs to another project')
        plain = final.with_suffix('')
        staged = plain.with_name('.backup-' + plain.name + '.partial')
        shutil.copyfile(decrypted, staged)
        os.replace(staged, plain)
    return plain


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
    with plaintext_archive(path) as plaintext, tempfile.TemporaryDirectory(prefix='backup-verify-') as temporary:
        return verify_root(extract(plaintext, Path(temporary)))


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
            subprocess.run(['age', '-d', '-i', str(identity_file()),
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


def database_counts(sql, environment):
    """Compare restored COPY inventories without exposing any row contents."""
    expected, table = {}, None
    identifier = r'(?:"(?:[^"]|"")+"|[A-Za-z_][\w$]*)'
    with Path(sql).open('rb') as stream:
        for line in stream:
            if table is not None:
                if line.rstrip(b'\r\n') == b'\\.':
                    table = None
                else:
                    expected[table] += 1
            elif line.startswith(b'COPY '):
                match = re.fullmatch(r'COPY (' + identifier + r'\.' + identifier + r') \(.*\) FROM stdin;\s*', line.decode())
                if not match:
                    raise ValueError('Unsupported SQL COPY inventory')
                table = match[1]
                expected[table] = 0
    if table is not None:
        raise ValueError('Incomplete SQL COPY inventory')
    if not expected:
        return {}
    query = ' UNION ALL '.join("SELECT '" + name.replace("'", "''") + "', count(*) FROM " + name for name in expected)
    result = run_pg(['psql', '-X', '-At', '-F', '|', '-v', 'ON_ERROR_STOP=1', '-c', query], environment=environment)
    actual = {name: int(count) for name, count in (line.rsplit('|', 1) for line in result.decode().splitlines())}
    if actual != expected:
        raise ValueError('Restored row counts do not match the snapshot')
    return actual


def replace_local(path, destination):
    """Stage and validate a local refresh; retain the previous database and media."""
    settings, storage = settings_and_storage()
    from django.core.files.storage import FileSystemStorage
    if not settings.DEBUG or not isinstance(storage, FileSystemStorage):
        raise ValueError('Local replacement requires development mode and local filesystem media')
    database = dict(settings.DATABASES['default'])
    if database['HOST'] not in ('db', 'localhost', '127.0.0.1', '::1'):
        raise ValueError('Local replacement cannot target a remote database')
    manifest = verify(path)
    if manifest['scope'] != 'full' or manifest.get('project') != os.getenv('PROJECT_HOST'):
        raise ValueError('Local refresh requires a full snapshot belonging to this project')
    environment = os.environ.copy()
    environment.pop('DATABASE_URL', None)
    environment.update(PGHOST=database['HOST'], PGPORT=str(database['PORT'] or 5432),
                       PGUSER=database['USER'], PGPASSWORD=database['PASSWORD'], PGDATABASE=database['NAME'])
    maintenance = {**environment, 'PGDATABASE': 'template1'}
    token = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S') + '_' + uuid.uuid4().hex[:6]
    staged_name = database['NAME'][:25] + '_restore_' + token
    retained_name = database['NAME'][:25] + '_saved_' + token
    quote = lambda name: '"' + name.replace('"', '""') + '"'
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    media_root = Path(storage.location).resolve()
    retained_media = destination / ('.backup-media-saved-' + token)
    # Refuse mount-point swaps rather than deleting or partially replacing uploads.
    if os.path.ismount(media_root):
        raise ValueError('Local media is a mount point; use an empty recovery destination instead')
    if os.stat(destination).st_dev != os.stat(media_root.parent).st_dev:
        raise ValueError('Local media and recovery storage require the same filesystem for an atomic swap')
    journal = destination / ('.backup-local-' + token + '.json')
    recovery = {'project': manifest['project'], 'snapshot': Path(path).name, 'database': database['NAME'],
                'staged_database': staged_name, 'retained_database': retained_name,
                'retained_media': str(retained_media), 'status': 'staging'}
    journal.write_text(json.dumps(recovery, indent=2), encoding='utf-8')
    with plaintext_archive(path) as plaintext, tempfile.TemporaryDirectory(prefix='.backup-refresh-', dir=destination) as temporary:
        root = extract(plaintext, Path(temporary))
        verify_root(root)
        sql = root / 'database.sql'
        run_pg(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-c', 'CREATE DATABASE ' + quote(staged_name) + ' TEMPLATE template0'], environment=maintenance)
        staged_environment = {**environment, 'PGDATABASE': staged_name}
        run_pg(['psql', '-X', '--single-transaction', '-v', 'ON_ERROR_STOP=1', '-f', str(sql)], environment=staged_environment)
        counts = database_counts(sql, staged_environment)
        from django.db import connections
        from django.core.management import call_command
        connection = connections['default']
        connection.close()
        connection.settings_dict['NAME'] = staged_name
        try:
            call_command('migrate', interactive=False, verbosity=0)
            connection.check_constraints()
        finally:
            connection.close()
            connection.settings_dict['NAME'] = database['NAME']
        # Expire only this local app's Django cache/session namespace. Leave
        # unrelated Redis keys and queued jobs intact, and never touch remote Redis.
        from django.core.cache import cache
        cache_location = settings.CACHES.get('default', {}).get('LOCATION', '')
        if isinstance(cache_location, str) and urlsplit(cache_location).hostname in ('redis', 'localhost', '127.0.0.1', '::1'):
            if getattr(cache, 'key_prefix', '') and hasattr(cache, 'delete_pattern'):
                cache.delete_pattern('*')
        # Application services are paused by dev.sh before this command runs.
        had_media = media_root.exists()
        if had_media:
            os.replace(media_root, retained_media)
        try:
            os.replace(root / 'media', media_root)
            literal = database['NAME'].replace("'", "''")
            run_pg(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='" + literal + "' AND pid <> pg_backend_pid()"], environment=maintenance)
            run_pg(['psql', '-X', '--single-transaction', '-v', 'ON_ERROR_STOP=1', '-c',
                    'ALTER DATABASE ' + quote(database['NAME']) + ' RENAME TO ' + quote(retained_name) + '; ' +
                    'ALTER DATABASE ' + quote(staged_name) + ' RENAME TO ' + quote(database['NAME'])], environment=maintenance)
        except Exception:
            if media_root.exists():
                os.replace(media_root, root / 'media')
            if had_media:
                os.replace(retained_media, media_root)
            raise
    recovery.update(status='complete', tables=len(counts), rows=sum(counts.values()))
    journal.write_text(json.dumps(recovery, indent=2), encoding='utf-8')
    return recovery


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['create', 'verify', 'restore', 'auto-restore', 'upload', 'download', 'replace-local'])
    parser.add_argument('path', nargs='?')
    parser.add_argument('--scope', choices=['full', 'db', 'index', 'media'], default='full')
    parser.add_argument('--allow-legacy', action='store_true')
    parser.add_argument('--project-tables', action='store_true')
    parser.add_argument('--root', default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument('--directory')
    parser.add_argument('--source', choices=['local', 'production'], default='local')
    parser.add_argument('--path-only', action='store_true')
    args = parser.parse_args()
    backup_dir = Path(args.directory or os.getenv('BACKUP_DIR', '/backend/backup'))
    if args.command == 'upload':
        candidates = [p for p in backup_dir.glob('snapshot_*') if p.name.endswith(('.tar.gz', '.tar.gz.age'))]
        archive = Path(args.path) if args.path else max(candidates, key=lambda p: (p.name.removesuffix('.age'), p.name), default=None)
        if archive is None:
            raise ValueError('Create a local snapshot before uploading')
        print(github_upload(archive, args.root))
    elif args.command == 'download':
        archive = github_download(backup_dir, args.root, args.source)
        if args.path_only:
            print(archive)
        else:
            print('Downloaded and verified: ' + str(archive))
            print('Restore this archive explicitly into an empty database/media destination.')
    elif args.command == 'replace-local':
        print(json.dumps(replace_local(args.path, backup_dir), indent=2))
    elif args.command == 'create':
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
