from django.test import SimpleTestCase, TestCase
from django.conf import settings
from django.urls import reverse, resolve
import os
import json
import plistlib
import unittest
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from . import watchos
from .project_config import exposure_check_command, is_shared, mobile_apps, sync_paths


class ProjectIsolationTests(SimpleTestCase):
    def test_checkout_identity_is_separate_from_accessible_source_bridge(self):
        from .project_config import check_project_isolation
        with TemporaryDirectory() as directory:
            root = Path(directory)
            container = {'Config': {'Labels': {
                'com.docker.compose.project': 'project',
                'com.docker.compose.project.working_dir': str(root / 'original'),
            }}}
            with patch.dict(os.environ, {
                'DEV_SOURCE_DIR': str(root / 'bridge'),
                'DEV_CHECKOUT_DIR': str(root / 'original'),
            }), patch('config.project_config.subprocess.check_output', side_effect=['id\n', json.dumps([container])]):
                check_project_isolation(root / 'runtime', 'project', ['project.localhost'])

    def test_retries_inventory_changed_by_concurrent_startup(self):
        from .project_config import check_project_isolation
        missing = subprocess.CalledProcessError(125, ['podman', 'inspect'])
        with patch('config.project_config.subprocess.check_output', side_effect=[
            'old\n', missing, 'new\n', '[]',
        ]) as command:
            check_project_isolation(Path.cwd(), 'project', ['project.localhost'])
        self.assertEqual(command.call_args_list[-1].args[0], ['podman', 'inspect', 'new'])

    def test_unchanged_inventory_inspection_failure_is_not_ignored(self):
        from .project_config import check_project_isolation
        missing = subprocess.CalledProcessError(125, ['podman', 'inspect'])
        with patch('config.project_config.subprocess.check_output', side_effect=['old\n', missing, 'old\n']):
            with self.assertRaises(subprocess.CalledProcessError):
                check_project_isolation(Path.cwd(), 'project', ['project.localhost'])

    def test_retried_inventory_still_rejects_hostname_overlap(self):
        from .project_config import check_project_isolation
        missing = subprocess.CalledProcessError(125, ['podman', 'inspect'])
        container = {'Config': {'Labels': {
            'com.docker.compose.project': 'other',
            'traefik.http.routers.other.rule': 'Host(`project.localhost`)',
        }}}
        with patch('config.project_config.subprocess.check_output', side_effect=[
            'old\n', missing, 'new\n', json.dumps([container]),
        ]):
            with self.assertRaisesRegex(ValueError, 'already routed'):
                check_project_isolation(Path.cwd(), 'project', ['project.localhost'])


class PortableBackupTests(SimpleTestCase):
    def test_local_refresh_refuses_production_before_any_database_operation(self):
        from types import SimpleNamespace
        from django.core.files.storage import FileSystemStorage
        from .backups import replace_local
        with TemporaryDirectory() as directory, patch('config.backups.run_pg') as pg:
            with patch('config.backups.settings_and_storage', return_value=(SimpleNamespace(DEBUG=False), FileSystemStorage(location=directory))):
                with self.assertRaisesRegex(ValueError, 'development mode'):
                    replace_local('snapshot.tar.gz', directory)
            pg.assert_not_called()

    def test_row_inventory_is_verified_without_sending_private_values_in_queries(self):
        from .backups import database_counts
        with TemporaryDirectory() as directory:
            sql = Path(directory) / 'database.sql'
            sql.write_text('COPY public.items (name) FROM stdin;\nPrivate Person\nAnother Person\n\\.\n')
            with patch('config.backups.run_pg', return_value=b'public.items|2\n') as pg:
                self.assertEqual(database_counts(sql, {}), {'public.items': 2})
                self.assertNotIn('Private Person', str(pg.call_args))
            with patch('config.backups.run_pg', return_value=b'public.items|1\n'):
                with self.assertRaisesRegex(ValueError, 'row counts'):
                    database_counts(sql, {})

    def test_failed_staging_preserves_the_current_database_and_media(self):
        from types import SimpleNamespace
        from django.core.files.storage import FileSystemStorage
        from .backups import create, replace_local
        with TemporaryDirectory() as directory, patch.dict(os.environ, {'BACKUP_AGE_RECIPIENT': '', 'PROJECT_HOST': 'project'}):
            root = Path(directory)
            media = root / 'media'
            media.mkdir()
            (media / 'private.txt').write_bytes(b'preserve this')
            storage = FileSystemStorage(location=media)
            def dump(command, output=None, **kwargs):
                output.write(b'-- SQL snapshot\n')
            with patch('config.backups.run_pg', side_effect=dump):
                archive = create(root / 'backup', 'full', storage=storage)
            settings = SimpleNamespace(DEBUG=True, DATABASES={'default': {'HOST': 'db', 'PORT': '5432', 'NAME': 'live', 'USER': 'user', 'PASSWORD': ''}})
            def stage(command, **kwargs):
                if '-f' in command:
                    raise RuntimeError('Simulated restore failure')
                self.assertNotIn('ALTER DATABASE', str(command))
                return b''
            with patch('config.backups.settings_and_storage', return_value=(settings, storage)), patch('config.backups.run_pg', side_effect=stage):
                with self.assertRaisesRegex(RuntimeError, 'restore failure'):
                    replace_local(archive, root / 'backup')
            self.assertEqual((media / 'private.txt').read_bytes(), b'preserve this')
            self.assertEqual(settings.DATABASES['default']['NAME'], 'live')
            self.assertTrue(archive.exists())

    def test_local_upload_encrypts_and_retries_without_replacing_production_tree(self):
        import base64
        import hashlib
        from django.core.files.storage import FileSystemStorage
        from .backups import create, github_upload, GitHubBackupError
        with TemporaryDirectory() as directory, patch.dict(os.environ, {'BACKUP_AGE_RECIPIENT': '', 'PROJECT_HOST': 'project'}):
            root = Path(directory) / 'project'
            root.mkdir()
            media = root / 'media'
            media.mkdir()
            (media / 'private.txt').write_text('private content')
            archive = create(root / 'backend/backup', 'media', storage=FileSystemStorage(location=media))
            calls, published = [], []

            def api(endpoint, data=None, method=None):
                calls.append((endpoint, data, method))
                if endpoint == 'git/blobs':
                    content = base64.b64decode(data['content'])
                    published.append(content)
                    return {'sha': hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()}
                if endpoint == 'git/ref/heads/production-backups':
                    return {'object': {'sha': 'original' if len([c for c in calls if c[0] == endpoint]) == 1 else 'concurrent'}}
                if endpoint.startswith('git/commits/'):
                    return {'tree': {'sha': 'existing-tree'}}
                if endpoint.startswith('git/trees/'):
                    return {'tree': [{'path': 'snapshots/production.tar.gz.age', 'type': 'blob', 'sha': 'production'}]}
                if endpoint == 'git/trees':
                    self.assertEqual(data['base_tree'], 'existing-tree')
                    self.assertTrue(all(item['path'].startswith('snapshots/local/')
                                        or item['path'] == 'frontend/web/vercel.json'
                                        for item in data['tree']))
                    self.assertEqual(sum(item['path'] == 'frontend/web/vercel.json'
                                         for item in data['tree']), 1)
                    return {'sha': 'new-tree'}
                if endpoint == 'git/commits':
                    return {'sha': 'new-commit'}
                if endpoint == 'git/refs/heads/production-backups':
                    self.assertFalse(data['force'])
                    if len([c for c in calls if c[0] == endpoint]) == 1:
                        raise GitHubBackupError(422)
                    return {}
                raise AssertionError(endpoint)

            def encrypt(command, **kwargs):
                Path(command[command.index('-o') + 1]).write_bytes(b'age-encryption.org/v1\nencrypted bytes')

            with patch('config.backups.subprocess.run', side_effect=encrypt):
                result = github_upload(archive, root, api=api, recipient='public-recipient')
            self.assertTrue(result.endswith('/snapshots/local'))
            self.assertTrue(archive.exists())
            self.assertEqual(len(published), 3)
            self.assertEqual(json.loads(published[0]), {'git': {'deploymentEnabled': False}})
            self.assertTrue(published[1].startswith(b'age-encryption.org/v1'))
            self.assertNotIn(b'private content', b''.join(published))
            self.assertEqual([c[1]['parents'] for c in calls if c[0] == 'git/commits'], [['original'], ['concurrent']])

    def test_local_upload_rejects_other_projects_before_any_remote_request(self):
        from django.core.files.storage import FileSystemStorage
        from .backups import create, github_upload
        with TemporaryDirectory() as directory, patch.dict(os.environ, {'BACKUP_AGE_RECIPIENT': '', 'PROJECT_HOST': 'other'}):
            root = Path(directory) / 'project'
            root.mkdir()
            media = root / 'media'
            media.mkdir()
            archive = create(root / 'archives', 'media', storage=FileSystemStorage(location=media))
            api = unittest.mock.Mock()
            with self.assertRaisesRegex(ValueError, 'another project'):
                github_upload(archive, root, api=api)
            api.assert_not_called()

    def test_download_checks_checksum_before_writing_or_decrypting(self):
        import base64
        from .backups import github_download
        with TemporaryDirectory() as directory:
            def api(endpoint, data=None, method=None):
                if endpoint == 'git/ref/heads/production-backups':
                    return {'object': {'sha': 'head'}}
                if endpoint.startswith('git/commits/'):
                    return {'tree': {'sha': 'tree'}}
                if endpoint.startswith('git/trees/'):
                    return {'tree': [{'type': 'blob', 'path': 'snapshots/local/snapshot_test.tar.gz.age', 'sha': 'archive'},
                                     {'type': 'blob', 'path': 'snapshots/local/snapshot_test.tar.gz.age.sha256', 'sha': 'checksum'}]}
                return {'content': base64.b64encode(b'age-encryption.org/v1\nbytes' if endpoint.endswith('/archive') else b'0' * 64).decode()}
            destination = Path(directory) / 'download'
            with patch('config.backups.plaintext_archive') as decrypt:
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    github_download(destination, directory, api=api)
                decrypt.assert_not_called()
            self.assertFalse(destination.exists())

    def test_media_archive_restores_exact_bytes_and_preserves_existing_uploads(self):
        from django.core.files.storage import FileSystemStorage
        from .backups import create, restore
        with TemporaryDirectory() as directory, patch.dict(os.environ, {'BACKUP_AGE_RECIPIENT': ''}):
            root = Path(directory)
            source = root / 'source'
            source.mkdir()
            (source / 'photo.bin').write_bytes(b'uploaded bytes')
            archive = create(root / 'archives', 'media', storage=FileSystemStorage(location=source))
            destination = FileSystemStorage(location=root / 'destination')
            with patch('config.backups.settings_and_storage', return_value=(None, destination)):
                restore(archive)
                self.assertEqual((root / 'destination/photo.bin').read_bytes(), b'uploaded bytes')
                with self.assertRaisesRegex(ValueError, 'empty media'):
                    restore(archive)

    def test_url_credentials_are_decoded_without_argv_exposure(self):
        from .backups import pg_environment
        with patch.dict(os.environ, {'DATABASE_URL': 'postgresql://user:p%40ss@[::1]:5433/db%20name?sslmode=require'}):
            env = pg_environment()
        self.assertEqual(env['PGPASSWORD'], 'p@ss')
        self.assertEqual(env['PGHOST'], '::1')
        self.assertEqual(env['PGDATABASE'], 'db name')
        self.assertEqual(env['PGSSLMODE'], 'require')

    def test_storage_failure_does_not_publish_partial_snapshot(self):
        from .backups import create
        storage = unittest.mock.Mock()
        storage.listdir.side_effect = OSError('unavailable')
        with TemporaryDirectory() as directory:
            with self.assertRaises(OSError):
                create(directory, 'media', storage=storage)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_manifest_detects_modified_media(self):
        from .backups import verify_root, digest
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'media').mkdir()
            media = root / 'media' / 'photo.jpg'
            media.write_bytes(b'original')
            (root / 'manifest.json').write_text(json.dumps({'format': 1, 'scope': 'media',
                'files': {'media/photo.jpg': {'bytes': 8, 'sha256': digest(media)}}}))
            verify_root(root)
            media.write_bytes(b'modified')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                verify_root(root)

    def test_archive_rejects_traversal_links_and_duplicate_names_before_extracting(self):
        import io
        import tarfile
        from .backups import extract
        for names in [('root/../../escape',), ('root/link',), ('root/file', 'root/file')]:
            with self.subTest(names=names), TemporaryDirectory() as directory:
                archive = Path(directory) / 'test.tar.gz'
                target = Path(directory) / 'target'
                target.mkdir()
                with tarfile.open(archive, 'w:gz') as stream:
                    for name in names:
                        member = tarfile.TarInfo(name)
                        if name.endswith('link'):
                            member.type = tarfile.SYMTYPE
                            member.linkname = '/etc/passwd'
                        else:
                            member.size = 1
                        stream.addfile(member, io.BytesIO(b'x'))
                with self.assertRaises(ValueError):
                    extract(archive, target)
                self.assertEqual(list(target.iterdir()), [])

    def test_database_restore_preserves_nonempty_target(self):
        from .backups import restore
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'seed.sql'
            path.write_text('DROP TABLE important;')
            with patch('config.backups.database_initialized', return_value=True), patch('config.backups.run_pg') as pg:
                with self.assertRaisesRegex(ValueError, 'empty database'):
                    restore(path, allow_legacy=True)
                pg.assert_not_called()


class RestoredSequenceTestCase(TestCase):
    def test_restored_ids_are_repaired_without_rewinding_ahead_sequences(self):
        from django.contrib.auth import get_user_model
        from django.db import connection
        from .project_config import repair_database_sequences
        if connection.vendor != 'postgresql':
            self.skipTest('PostgreSQL sequence repair')
        User = get_user_model()
        table = User._meta.db_table
        User.objects.create(username='restored-sequence-user', pk=50000)
        with connection.cursor() as cursor:
            cursor.execute('SELECT pg_get_serial_sequence(%s, %s)', [table, User._meta.pk.column])
            sequence = cursor.fetchone()[0]
            cursor.execute('SELECT setval(%s::regclass, 1, true)', [sequence])
        repair_database_sequences(connection)
        created = User.objects.create(username='after-restored-sequence')
        self.assertGreater(created.pk, 50000)
        with connection.cursor() as cursor:
            cursor.execute('SELECT setval(%s::regclass, 70000, true)', [sequence])
        repair_database_sequences(connection)
        self.assertGreater(User.objects.create(username='after-ahead-sequence').pk, 70000)

    def test_unrelated_tables_in_shared_database_are_untouched(self):
        from django.db import connection
        from .project_config import repair_database_sequences
        if connection.vendor != 'postgresql':
            self.skipTest('PostgreSQL sequence repair')
        with connection.cursor() as cursor:
            cursor.execute('CREATE TABLE config_foreign_sequence_probe (id bigserial PRIMARY KEY)')
            cursor.execute('INSERT INTO config_foreign_sequence_probe (id) VALUES (50000)')
            cursor.execute('SELECT last_value FROM config_foreign_sequence_probe_id_seq')
            previous = cursor.fetchone()[0]
        repair_database_sequences(connection)
        with connection.cursor() as cursor:
            cursor.execute('SELECT last_value FROM config_foreign_sequence_probe_id_seq')
            self.assertEqual(cursor.fetchone()[0], previous)


class ProjectEnvironmentTestCase(unittest.TestCase):
    def test_project_commands_do_not_inherit_missing_application_secrets(self):
        from .project_config import project_environment
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'backend').mkdir()
            (root / 'backend/project.py').write_text("import os\nKEY = os.getenv('INTEGRATION_SECRET')\n")
            (root / '.env').write_text('DOMAIN=selected.example\n')
            with patch.dict(os.environ, {'INTEGRATION_SECRET': 'other-project-secret',
                                         'EXPO_PUBLIC_FOREIGN_KEY': 'foreign',
                                         'NEXT_PUBLIC_FOREIGN_KEY': 'foreign',
                                         'PATH': 'host-tools'}):
                environment = project_environment(root)
            self.assertNotIn('INTEGRATION_SECRET', environment)
            self.assertNotIn('EXPO_PUBLIC_FOREIGN_KEY', environment)
            self.assertNotIn('NEXT_PUBLIC_FOREIGN_KEY', environment)
            self.assertEqual(environment['PATH'], 'host-tools')
            self.assertEqual(environment['DOMAIN'], 'selected.example')

    def test_selected_checkout_does_not_inherit_another_projects_values(self):
        from .project_config import environment_values, mobile_build_environment
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / '.env').write_text('EXPO_PUBLIC_API_URL=https://selected.example/api\nDB_NAME=selected\n')
            with patch.dict(os.environ, {'EXPO_PUBLIC_API_URL': 'https://other.example/api',
                                         'EXPO_PUBLIC_FOREIGN_KEY': 'foreign', 'DB_NAME': 'other'}):
                values = environment_values(root)
                self.assertEqual(values['DB_NAME'], 'selected')
                self.assertEqual(environment_values(root, include_environment=True)['DB_NAME'], 'selected')
                public = mobile_build_environment(root, 'development')
            self.assertEqual(public['EXPO_PUBLIC_API_URL'], 'https://selected.example/api')
            self.assertNotIn('EXPO_PUBLIC_FOREIGN_KEY', public)

    def test_discovery_ignores_comments_tests_and_sibling_projects(self):
        from .project_config import environment_keys
        with TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = parent / 'selected'
            (root / 'backend').mkdir(parents=True)
            (root / 'frontend').mkdir()
            (root / 'backend/project.py').write_text(
                "# os.getenv('COMMENTED_INTEGRATION')\nimport os\nACTIVE = os.getenv('ACTIVE_KEY')\n")
            (root / 'backend/tests.py').write_text("import os\nKEY = os.getenv('TEST_KEY')\n")
            (root / 'frontend/app.ts').write_text(
                "// process.env.COMMENTED_PUBLIC_KEY\nconst url = 'https://example.test';\n"
                "const key = process.env.NEXT_PUBLIC_ACTIVE_KEY;\n")
            (parent / 'other.py').write_text("import os\nKEY = os.getenv('OTHER_PROJECT_KEY')\n")
            self.assertEqual(environment_keys(root), {'ACTIVE_KEY', 'NEXT_PUBLIC_ACTIVE_KEY'})

    def test_bootstrap_uses_project_defaults_and_distinct_keys_without_overwriting(self):
        from .project_config import bootstrap_environment, environment_values
        with TemporaryDirectory() as temporary:
            roots = [Path(temporary) / name for name in ('first', 'second')]
            for root in roots:
                (root / 'backend').mkdir(parents=True)
                (root / 'backend/project.py').write_text(
                    "import os\nSECRET_KEY = os.getenv('DJANGO_SECRET_KEY')\n"
                    "ENV_DEFAULTS = {'PROJECT_INTEGRATION_KEY': ''}\n")
                bootstrap_environment(root)
            first, second = map(environment_values, roots)
            self.assertNotEqual(first['DJANGO_SECRET_KEY'], second['DJANGO_SECRET_KEY'])
            self.assertIn('PROJECT_INTEGRATION_KEY', first)
            source = roots[0] / '.env'
            source.write_text('DJANGO_SECRET_KEY=keep-existing\n')
            bootstrap_environment(roots[0])
            self.assertEqual(source.read_text(), 'DJANGO_SECRET_KEY=keep-existing\n')

    def test_project_environment_and_settings_are_never_template_synced(self):
        self.assertFalse(is_shared('.env'))
        self.assertFalse(is_shared('frontend/web/.env.local'))
        self.assertFalse(is_shared('backend/project.py'))


class WatchOSLauncherTestCase(unittest.TestCase):
    def test_exposure_allows_automatic_quick_tunnel_and_validates_named_origin(self):
        from . import project_config
        command = ['python', 'manage.py', 'project_security_check']
        with patch.object(project_config, 'project_option', return_value=command):
            for url, token, valid in [('https://watch.example.test', 'test-token', True),
                                      ('https://watch.example.test', '', True),
                                      ('', '', True),
                                      ('https://temporary.trycloudflare.com', '', True),
                                      ('https://temporary.trycloudflare.com', 'test-token', False),
                                      ('http://watch.example.test', 'test-token', False),
                                      ('https://user:password@watch.example.test', 'test-token', False)]:
                values = {'CLOUDFLARE_TUNNEL_URL': url, 'CLOUDFLARE_TUNNEL_TOKEN': token}
                with patch.object(project_config, 'environment_values', return_value=values):
                    if valid:
                        self.assertEqual(exposure_check_command(Path('.')), command)
                    else:
                        with self.assertRaises(ValueError):
                            exposure_check_command(Path('.'))

    def test_launch_installs_matching_bundle_on_watch_simulator(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            application = root / 'frontend/mobile/builds/Native/watchos/development/Build/Products/Debug-watchsimulator/Native.app'
            application.mkdir(parents=True)
            with (application / 'Info.plist').open('wb') as output:
                plistlib.dump({'CFBundleIdentifier': 'test.native'}, output)
            devices = {'devices': {'com.apple.CoreSimulator.SimRuntime.watchOS-26-0': [
                {'udid': 'watch', 'isAvailable': True, 'state': 'Shutdown'}]}}
            args = type('Arguments', (), {'app': 'Native', 'simulator': None, 'device': False})()
            with patch.object(watchos.subprocess, 'check_output', return_value=json.dumps(devices)), \
                 patch.object(watchos, 'run') as execute:
                watchos.launch(root, args, {'scheme': 'Native', 'bundle_id': 'test.native'})
            self.assertIn(unittest.mock.call('xcrun', 'simctl', 'boot', 'watch'), execute.call_args_list)
            self.assertIn(unittest.mock.call('xcrun', 'simctl', 'install', 'watch', str(application)), execute.call_args_list)
            self.assertEqual(execute.call_args_list[-1], unittest.mock.call(
                'xcrun', 'simctl', 'launch', '--terminate-running-process', 'watch', 'test.native'))

    def test_simulator_selection_uses_watch_runtime_and_prefers_booted(self):
        devices = {'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-26-0': [
                {'udid': 'phone', 'isAvailable': True, 'state': 'Booted'}],
            'com.apple.CoreSimulator.SimRuntime.watchOS-26-0': [
                {'udid': 'offline', 'isAvailable': False, 'state': 'Booted'},
                {'udid': 'stopped', 'isAvailable': True, 'state': 'Shutdown'},
                {'udid': 'watch', 'isAvailable': True, 'state': 'Booted'}],
        }}
        self.assertEqual(watchos.simulator_id(devices), 'watch')
        self.assertEqual(watchos.simulator_id(devices, 'stopped'), 'stopped')
        with self.assertRaises(ValueError):
            watchos.simulator_id(devices, 'phone')

    def test_watch_configuration_contains_only_public_origins(self):
        values = {'CLOUDFLARE_TUNNEL_URL': 'https://dev.example.test/',
                  'EXPO_PUBLIC_API_URL_PRODUCTION': 'https://app.example.test/api',
                  'DJANGO_SECRET_KEY': 'private-value'}
        with patch.object(watchos, 'environment_values', return_value=values):
            self.assertEqual(watchos.public_configuration(Path('.'), 'development'), {
                'profile': 'development', 'webURL': 'https://dev.example.test',
                'apiURL': 'https://dev.example.test/api',
            })
            self.assertEqual(watchos.public_configuration(Path('.'), 'production')['apiURL'],
                             'https://app.example.test/api')
        for url in ('http://example.test', 'https://user:password@example.test',
                    'https://example.test/other', 'https://example.test?token=secret'):
            with patch.object(watchos, 'environment_values', return_value={'WATCH_WEB_URL': url}):
                with self.assertRaises(ValueError):
                    watchos.public_configuration(Path('.'), 'development')

    def test_production_never_uses_development_tunnel(self):
        with patch.object(watchos, 'environment_values', return_value={
                'CLOUDFLARE_TUNNEL_URL': 'https://dev.example.test'}):
            with self.assertRaises(ValueError):
                watchos.public_configuration(Path('.'), 'production')

    def test_native_watch_app_is_not_a_metro_app_and_is_sync_protected(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'backend').mkdir()
            directory = root / 'frontend/mobile/Native/watchos'
            directory.mkdir(parents=True)
            (root / 'backend/project.py').write_text(
                "WATCHOS_APPS = {'Native': {'path': 'frontend/mobile/Native/watchos', "
                "'scheme': 'Native', 'bundle_id': 'test.native'}}\n")
            self.assertEqual(mobile_apps(root), [])
            self.assertIn('frontend/mobile/Native/watchos/', sync_paths(root))
            config, found = watchos.app_settings(root, 'native')
            self.assertEqual(found, directory)
            self.assertEqual(config['scheme'], 'Native')
            self.assertFalse(is_shared('frontend/mobile/Native/watchos/project.yml'))
            self.assertTrue(is_shared('backend/config/watchos.py'))
            with self.assertRaises(ValueError):
                watchos.app_settings(root, 'missing')
            with patch.object(watchos, 'project_option', return_value={
                    'escape': {'path': '../', 'scheme': 'Escape', 'bundle_id': 'test.escape'}}):
                with self.assertRaises(ValueError):
                    watchos.app_settings(root, 'escape')

    def test_build_profiles_select_simulator_or_signed_archive(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / 'frontend/mobile/Native/watchos'
            directory.mkdir(parents=True)
            (directory / 'Native.xcodeproj').mkdir()
            config = {'scheme': 'Native', 'bundle_id': 'test.native'}
            with patch.object(watchos, 'environment_values', return_value={
                    'WATCH_WEB_URL': 'https://dev.example.test',
                    'WATCH_WEB_URL_PRODUCTION': 'https://app.example.test'}), \
                 patch.object(watchos, 'run') as execute:
                for profile in ('development', 'production'):
                    args = type('Arguments', (), {'profile': profile, 'app': 'Native', 'device': False})()
                    watchos.build(root, args, config, directory)
                development, production = [call.args for call in execute.call_args_list]
                self.assertIn('watchsimulator', development)
                self.assertIn('CODE_SIGNING_ALLOWED=NO', development)
                self.assertIn('archive', production)
                self.assertIn('generic/platform=watchOS', production)
                self.assertNotIn('CODE_SIGNING_ALLOWED=NO', production)


class MediaURLConfigurationTestCase(SimpleTestCase):
    """Test cases for media URL configuration (no database needed)

Note: Django's test runner sets DEBUG=False during tests, so media URLs
won't be served during testing. These tests verify the configuration.
"""

    def test_media_url_code_has_show_indexes(self):
        """Test that the URLs module configures show_indexes=True for media when DEBUG=True"""
        # Read the actual urls.py file to verify the configuration
        urls_file_path = os.path.join(
            os.path.dirname(__file__), 
            'urls.py'
        )

        with open(urls_file_path, 'r') as f:
            urls_content = f.read()

        # Verify that show_indexes is set to True in the code
        self.assertIn('"show_indexes": True', urls_content,
                      "show_indexes should be set to True in urls.py")

        # Verify it's within the DEBUG check
        self.assertIn("if settings.DEBUG:", urls_content,
                      "Media serving should be conditional on DEBUG")

        # Verify we're using django.views.static.serve
        self.assertIn("from django.views.static import serve", urls_content,
                      "Should import serve from django.views.static")

    def test_media_root_configuration(self):
        """Test that MEDIA_ROOT and MEDIA_URL are properly configured"""
        self.assertTrue(hasattr(settings, 'MEDIA_ROOT'))
        self.assertTrue(hasattr(settings, 'MEDIA_URL'))

        # In development, MEDIA_URL should be '/media/'
        # In production with GCS, it will be a GCS URL
        if settings.DEBUG:
            self.assertEqual(settings.MEDIA_URL, '/media/')
        else:
            # In production, MEDIA_URL could be a GCS URL or local fallback
            self.assertTrue(settings.MEDIA_URL.startswith(('http://', 'https://', '/media/')))

    def test_storage_backend_configuration(self):
        """Storage may be local or supplied by any project's overrides."""
        self.assertIn('default', settings.STORAGES)
        self.assertIn('BACKEND', settings.STORAGES['default'])
        self.assertIn('staticfiles', settings.STORAGES)


class AdminLoginURLTestCase(TestCase):
    """Test cases for admin login URL configuration"""

    def test_admin_login_url_resolves_correctly(self):
        """Test that /api/admin/login/ resolves to custom admin_login view"""
        # Resolve the URL and check it goes to the correct view
        resolved = resolve('/api/admin/login/')

        # The view function should be admin_login, not Django's admin login
        self.assertEqual(resolved.view_name, 'admin-login',
                        "/api/admin/login/ should resolve to custom admin-login view")

    def test_admin_login_requires_credentials(self):
        """Test that admin_login endpoint requires username and password"""
        # Try to POST without credentials
        response = self.client.post('/api/admin/login/',
                                   content_type='application/json',
                                   data='{}')

        # Should return 400 Bad Request for missing credentials
        self.assertEqual(response.status_code, 400)
        data = response.json()
        self.assertIn('error', data)

    def test_admin_login_rejects_invalid_credentials(self):
        """Test that admin_login rejects invalid credentials"""
        # Try to POST with invalid credentials
        response = self.client.post('/api/admin/login/',
                                   content_type='application/json',
                                   data='{"username": "invalid", "password": "wrong"}')

        # Should return 401 Unauthorized
        self.assertEqual(response.status_code, 401)
        data = response.json()
        self.assertIn('error', data)

    def test_admin_login_requires_staff_permission(self):
        """Test that admin_login requires user to be staff"""
        from django.contrib.auth import get_user_model
        User = get_user_model()

        # Create a regular user (not staff)
        regular_user = User.objects.create_user(
            username='regular',
            password='testpass123',
            is_staff=False
        )

        # Try to login with non-staff user
        response = self.client.post('/api/admin/login/',
                                   content_type='application/json',
                                   data='{"username": "regular", "password": "testpass123"}')

        # Should return 401 Unauthorized
        self.assertEqual(response.status_code, 401)
        data = response.json()
        self.assertIn('error', data)

    def test_admin_login_accepts_staff_credentials(self):
        """Test that admin_login accepts valid staff credentials"""
        from django.contrib.auth import get_user_model
        User = get_user_model()

        # Create a staff user
        staff_user = User.objects.create_user(
            username='config-test-staff',
            password='admin',
            is_staff=True
        )

        # Try to login with staff credentials
        response = self.client.post('/api/admin/login/',
                                   content_type='application/json',
                                   data='{"username": "config-test-staff", "password": "admin"}')

        # Should return 200 OK
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertTrue(data.get('success'))
        self.assertEqual(data.get('username'), 'config-test-staff')


class TemplateSyncTests(SimpleTestCase):
    def test_project_relocation_preserves_legacy_file_and_refuses_conflicting_destination(self):
        from .project_config import run_sync
        with TemporaryDirectory() as directory:
            template, project = (Path(directory) / name for name in ('template', 'project'))
            for root in (template, project):
                (root / 'backend/config').mkdir(parents=True)
                (root / 'backend/project.py').write_text(
                    "SYNC_TEMPLATE_REPO = 'owner/template'\nSYNC_RELOCATIONS = {'backend/config/legacy-tool': 'backend/helper/tool'}\n")
                if root == project:
                    (root / 'backend/config/legacy-tool').write_text('custom content')
                for command in (['init', '-q'], ['add', '.'],
                                ['-c', 'user.name=Test', '-c', 'user.email=test@example.test', 'commit', '-qm', 'initial']):
                    subprocess.run(['git', '-C', str(root), *command], check=True)
            target = project / 'backend/helper/tool'
            target.parent.mkdir()
            target.write_text('different content')
            with self.assertRaisesRegex(ValueError, 'Relocation destination differs'):
                run_sync(project, ['--dir', str(template), '--yes'])
            self.assertEqual((project / 'backend/config/legacy-tool').read_text(), 'custom content')
            target.unlink()
            run_sync(project, ['--dir', str(template), '--dry-run'])
            self.assertFalse(target.exists())
            run_sync(project, ['--dir', str(template), '--yes'])
            self.assertEqual(target.read_text(), 'custom content')
            self.assertFalse((project / 'backend/config/legacy-tool').exists())
            (project / 'backend/project.py').write_text("SYNC_TEMPLATE_REPO = 'owner/template'\nSYNC_RELOCATIONS = {'backend/config/legacy': '../outside'}\n")
            with self.assertRaisesRegex(ValueError, 'stay inside the checkout'):
                run_sync(project, ['--dir', str(template), '--dry-run'])


    def test_reusable_django_apps_sync_while_business_apps_are_protected(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("mailroom", "catalog"):
                app = root / "backend" / name
                app.mkdir(parents=True)
                (app / "__init__.py").touch()
            protected = sync_paths(root)
            self.assertNotIn("backend/mailroom/", protected)
            self.assertIn("backend/catalog/", protected)
            self.assertTrue(is_shared("backend/mailroom/models.py", protected))


    def test_line_endings_do_not_create_shared_updates(self):
        from .project_config import same_shared_content
        self.assertTrue(same_shared_content(b'first\r\nsecond\r\n', b'first\nsecond\n'))
        self.assertFalse(same_shared_content(b'old\n', b'new\n'))
        self.assertFalse(same_shared_content(None, b''))

    def test_checkout_lock_prevents_parallel_sync_and_releases(self):
        from .project_config import sync_checkout_lock
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            with sync_checkout_lock(root):
                with self.assertRaisesRegex(ValueError, 'Another template sync'):
                    with sync_checkout_lock(root):
                        pass
            with sync_checkout_lock(root):
                pass

    def test_sync_preserves_app_work_and_rejects_conflicting_shared_edits(self):
        from .project_config import run_sync
        with TemporaryDirectory() as temporary:
            template, project = (Path(temporary) / name for name in ('template', 'project'))
            for root in (template, project):
                root.mkdir()
                (root / 'backend').mkdir()
                (root / 'backend/project.py').write_text("SYNC_TEMPLATE_REPO = 'owner/template'\n")
                (root / 'dev.sh').write_text('original\n')
                (root / 'application.txt').write_text('app original\n')
                for command in (['init', '-q'], ['add', '.'],
                                ['-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'initial']):
                    subprocess.run(['git', '-C', str(root), *command], check=True)
            (template / 'dev.sh').write_text('upstream\n')
            (project / 'application.txt').write_text('work in progress\n')
            run_sync(project, ['--dir', str(template), '--yes'])
            self.assertEqual((project / 'application.txt').read_text(), 'work in progress\n')
            self.assertEqual((project / 'dev.sh').read_text(), 'upstream\n')
            mirror = Path(temporary) / 'runtime-mirror'
            mirror.mkdir()
            with patch.dict(os.environ, {'DEV_SOURCE_DIR': str(project)}):
                self.assertEqual(run_sync(mirror, ['--dir', str(template), '--yes']), 0)
            (project / 'dev.sh').write_text('concurrent shared work\n')
            with self.assertRaisesRegex(ValueError, 'unpublished local edits'):
                run_sync(project, ['--dir', str(template), '--yes'])
            self.assertEqual((project / 'dev.sh').read_text(), 'concurrent shared work\n')

    def test_web_sync_preserves_project_dependencies_scripts_and_identity(self):
        from .project_config import merge_web_package
        template = {'dependencies': {'next': '16.4.0', 'react': '19.3.0'},
                    'devDependencies': {'typescript': '5.9.3'},
                    'scripts': {'build': 'next build --webpack', 'typecheck': 'tsc --noEmit'},
                    'engines': {'node': '>=24 <25'}}
        project = {'name': 'custom-app', 'dependencies': {'next': '15.0.0', 'stripe': 'custom'},
                   'scripts': {'postinstall': 'custom-command', 'export': 'next export'},
                   'devDependencies': {'custom-tool': '1'}}
        merged = json.loads(merge_web_package(json.dumps(template).encode(), json.dumps(project).encode()))
        self.assertEqual(merged['name'], 'custom-app')
        self.assertEqual(merged['dependencies'], {'next': '16.4.0', 'react': '19.3.0', 'stripe': 'custom'})
        self.assertEqual(merged['scripts']['postinstall'], 'custom-command')
        self.assertNotIn('export', merged['scripts'])
        self.assertEqual(merged['devDependencies']['custom-tool'], '1')
        self.assertEqual(merged['scripts']['build'], 'next build --webpack')

    def test_requirement_sync_preserves_project_integrations(self):
        from .project_config import merge_requirements
        template = b'Django==5.2.18\n\n# Project-specific integrations\ntemplate-only==1\n'
        project = b'Django==4.2.16\n\n# Project-specific integrations\nproject-only==2\n'
        merged = merge_requirements(template, project)
        self.assertIn(b'Django==5.2.18', merged)
        self.assertIn(b'project-only==2', merged)
        self.assertNotIn(b'template-only', merged)

    def test_sync_does_not_downgrade_newer_project_versions(self):
        from .project_config import merge_requirements, merge_web_package
        template = {'dependencies': {'next': '16.4.0'}}
        project = {'dependencies': {'next': '16.4.1'}}
        merged = json.loads(merge_web_package(json.dumps(template).encode(), json.dumps(project).encode()))
        self.assertEqual(merged['dependencies']['next'], '16.4.1')
        merged_requirements = merge_requirements(b'Django==5.2.18\n', b'Django==5.2.19\n')
        self.assertIn(b'Django==5.2.19', merged_requirements)
