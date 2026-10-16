from django.test import SimpleTestCase, TestCase
from django.conf import settings
from django.urls import reverse, resolve
import os
import json
import unittest
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from . import watchos
from .project_config import exposure_check_command, is_shared, mobile_apps, sync_paths


class LocalNetworkTests(SimpleTestCase):
    def test_lan_uses_the_interface_prefix_instead_of_assuming_a_24_bit_network(self):
        from .network import local_subnet
        interfaces = [{'addr_info': [{'local': '192.168.4.2', 'prefixlen': 22}]}]
        with patch('config.network.sys.platform', 'linux'), patch('config.network.subprocess.check_output', return_value=json.dumps(interfaces)):
            self.assertEqual(str(local_subnet('192.168.4.2')), '192.168.4.0/22')

    def test_local_names_follow_folder_but_existing_resource_identity_is_preserved(self):
        from .network import configure
        with TemporaryDirectory() as temporary:
            root = Path(temporary) / 'Renamed.app'
            (root / 'backend').mkdir(parents=True)
            (root / 'backend/project.py').write_text("DEV_RESOURCE_NAMESPACE = 'existingdata'\n")
            directory = Path(temporary) / 'routing'
            result = configure(root, 'on', directory)
            self.assertEqual(result['host'], 'dev.renamed.app')
            self.assertTrue((directory / 'existingdata-lan.yml').exists())
            configure(root, 'off', directory)
            self.assertEqual(list(directory.iterdir()), [])

    def test_lan_routes_are_scoped_and_do_not_publish_backend_or_dashboard_ports(self):
        from .network import lan_routes
        config = lan_routes('project', 'dev.project.app')
        for router in config['http']['routers'].values():
            self.assertEqual(router['entryPoints'], ['lan'])
            self.assertEqual(router['tls'], {'certResolver': 'dev'})
            self.assertIn('Host(`dev.project.app`)', router['rule'])
            self.assertIn('project-lan-relay', router['middlewares'])
            self.assertNotIn('api@internal', router['service'])
        self.assertEqual(config['http']['middlewares']['project-lan-relay']['ipAllowList']['sourceRange'],
                         ['127.0.0.1/32', '::1/128'])

    def test_development_hostname_uses_only_selected_checkout_settings(self):
        from .project_config import development_hostname
        with TemporaryDirectory() as directory:
            root = Path(directory) / 'My-Project.app'
            (root / 'backend').mkdir(parents=True)
            with patch.dict(os.environ, {'DEV_DOMAIN': 'wrong.example.com', 'DEV_HOST': 'wrong.example.com'}):
                self.assertEqual(development_hostname(root), 'dev.my-project.app')
                (root / 'backend/project.py').write_text("DEV_DOMAIN = 'owned.example.com'\nraise RuntimeError('must not import')\n")
                self.assertEqual(development_hostname(root), 'dev.owned.example.com')
                (root / '.env').write_text('DEV_DOMAIN="buecher.example.com"\n')
                self.assertEqual(development_hostname(root), 'dev.buecher.example.com')
                (root / '.env').write_text('DEV_DOMAIN=bücher.de\n', encoding='utf-8')
                self.assertEqual(development_hostname(root), 'dev.xn--bcher-kva.de')
                for invalid in ['https://owned.example.com', 'owned.example.com:443', 'foo.local', '127.0.0.1', '../other', 'foo..com', '*.example.com']:
                    (root / '.env').write_text('DEV_DOMAIN=' + invalid + '\n')
                    with self.subTest(domain=invalid), self.assertRaises(ValueError):
                        development_hostname(root)

    def test_off_revokes_routes_even_after_domain_configuration_breaks(self):
        from .network import configure
        with TemporaryDirectory() as directory:
            root = Path(directory) / 'project.app'
            root.mkdir()
            state = Path(directory) / 'routing'
            configure(root, 'on', state)
            (root / '.env').write_text('DEV_DOMAIN=broken\n')
            self.assertFalse(configure(root, 'off', state)['enabled'])
            self.assertEqual(list(state.iterdir()), [])

    def test_clean_non_domain_checkout_starts_locally_without_dns_configuration(self):
        from .project_config import development_hostname
        from .network import configure
        with TemporaryDirectory() as directory:
            root = Path(directory) / 'My New Project'
            root.mkdir()
            self.assertEqual(development_hostname(root), 'dev.my-new-project.localhost')
            state = Path(directory) / 'routing'
            with self.assertRaises(ValueError):
                configure(root, 'on', state)
            self.assertFalse(configure(root, 'off', state)['enabled'])
            self.assertFalse(state.exists())

    def test_enabled_hosts_rejects_old_aliases_and_malformed_state(self):
        from .network import enabled_hosts
        with TemporaryDirectory() as directory:
            for number, host in enumerate(['dev.project.app', 'project.app.local', 'dev.foo.local', 'dev.a..com', 'elsewhere.app', None]):
                (Path(directory) / f'{number}-lan.state').write_text(json.dumps({'host': host}))
            for number, value in enumerate([None, [], 'string', 7], start=10):
                (Path(directory) / f'{number}-lan.state').write_text(json.dumps(value))
            self.assertEqual(enabled_hosts(directory), {'dev.project.app'})

    def test_discovered_or_routes_cannot_escape_the_project_hostname(self):
        from .network import discovered_routes
        rule = 'Host(`dev.project.app`) || PathPrefix(`/socket`)'
        labels = {'traefik.http.routers.project-games.rule': rule,
                  'traefik.http.routers.project-games.entrypoints': 'websecure',
                  'traefik.http.routers.project-games.service': 'project-games'}
        with patch('config.network.subprocess.check_output', side_effect=['id\n', json.dumps([{'Config': {'Labels': labels}}])]):
            routes = discovered_routes('project', 'dev.project.app')
        self.assertEqual(routes['project-games-lan']['rule'], f'Host(`dev.project.app`) && ({rule})')

    def test_relay_shares_a_short_host_snapshot_and_fails_closed_on_read_failure(self):
        from .network import Relay
        with Relay(('127.0.0.1', 0), None) as relay:
            relay.directory = 'unused'
            with patch('config.network.time.monotonic', return_value=10) as clock, \
                    patch('config.network.enabled_hosts', return_value={'dev.project.app'}) as read:
                self.assertEqual(relay.allowed_hosts(), {'dev.project.app'})
                for _ in range(50):
                    self.assertEqual(relay.allowed_hosts(), {'dev.project.app'})
                read.assert_called_once_with('unused')
                clock.return_value = 10.26
                read.return_value = set()
                self.assertEqual(relay.allowed_hosts(), set())
                self.assertEqual(read.call_count, 2)
                clock.return_value = 10.52
                read.side_effect = OSError('temporarily unavailable')
                self.assertEqual(relay.allowed_hosts(), set())

    def test_listener_readiness_is_removed_on_exit_and_preserves_a_replacement(self):
        from .network import listener_readiness
        with TemporaryDirectory() as temporary:
            marker = Path(temporary) / 'ready.json'
            with listener_readiness(marker, '192.168.1.2'):
                self.assertEqual(json.loads(marker.read_text()), {'pid': os.getpid(), 'address': '192.168.1.2'})
            self.assertFalse(marker.exists())
            with listener_readiness(marker, '192.168.1.2'):
                marker.write_text(json.dumps({'pid': os.getpid() + 1}))
            self.assertTrue(marker.exists())

    def test_tls_hostname_uses_real_clienthello_and_rejects_incomplete_input(self):
        import ssl
        from .network import hello_hostname
        incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
        connection = ssl.create_default_context().wrap_bio(incoming, outgoing, server_hostname='dev.project.app')
        try:
            connection.do_handshake()
        except ssl.SSLWantReadError:
            pass
        packet = outgoing.read()
        self.assertEqual(hello_hostname(packet), 'dev.project.app')
        self.assertIsNone(hello_hostname(packet[:30]))
        self.assertIsNone(hello_hostname(b'GET / HTTP/1.1'))

    def test_relay_rejects_disabled_projects_and_closes_live_connections_on_off(self):
        import ipaddress
        import socket
        import socketserver
        import ssl
        import threading
        import time
        from .network import Relay, Forward, configure
        class Upstream(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(4)
                self.request.recv(65536)
                self.request.sendall(b'CONNECTED')
                self.request.recv(1)
        with TemporaryDirectory() as directory:
            root = Path(directory) / 'project.app'
            root.mkdir()
            state = Path(directory) / 'routing'
            configure(root, 'on', state)
            output = ssl.MemoryBIO()
            connection = ssl.create_default_context().wrap_bio(ssl.MemoryBIO(), output, server_hostname='dev.project.app')
            try:
                connection.do_handshake()
            except ssl.SSLWantReadError:
                pass
            hello = output.read()
            with socketserver.ThreadingTCPServer(('127.0.0.1', 0), Upstream) as upstream, Relay(('127.0.0.1', 0), Forward) as relay:
                relay.network = ipaddress.ip_network('127.0.0.0/8')
                relay.directory, relay.upstream = state, upstream.server_address
                workers = [threading.Thread(target=server.serve_forever, daemon=True) for server in [upstream, relay]]
                for worker in workers:
                    worker.start()
                try:
                    with socket.create_connection(relay.server_address, timeout=4) as client:
                        client.sendall(hello)
                        self.assertEqual(client.recv(9), b'CONNECTED')
                        revoked = time.monotonic()
                        configure(root, 'off', state)
                        self.assertEqual(client.recv(1), b'')
                        self.assertLess(time.monotonic() - revoked, 1)
                    with socket.create_connection(relay.server_address, timeout=4) as client:
                        client.sendall(hello)
                        self.assertEqual(client.recv(1), b'')
                finally:
                    relay.shutdown()
                    upstream.shutdown()
                    for worker in workers:
                        worker.join(3)


class DevelopmentDnsTests(SimpleTestCase):
    def setUp(self):
        from unittest.mock import Mock
        from . import development_dns
        self.dns = development_dns
        self.hostname = 'dev.example.com'
        self.zone = {'id': 'a' * 32, 'name': 'example.com', 'status': 'active'}
        self.marker = 'managed-by-project-development:' + self.hostname
        self.client = Mock()
        self.client.request.side_effect = lambda method, path, data: {'result': data}
        self.set_public_mode = self.dns.set_public_mode
        mode_patch = patch.object(self.dns, 'set_public_mode')
        self.mode_write = mode_patch.start()
        self.addCleanup(mode_patch.stop)

    def context(self, records):
        return patch.object(self.dns, '_context', return_value=(self.hostname, self.client, self.zone, records))

    def record(self, **changes):
        return {'id': 'b' * 32, 'type': 'A', 'name': self.hostname, 'content': '192.168.1.2',
                'ttl': 60, 'proxied': False, 'comment': self.marker, **changes}

    def test_creates_only_an_owned_dns_only_development_record(self):
        with self.context([]):
            self.assertEqual(self.dns.sync('.', '192.168.1.2')['action'], 'created')
        method, path, payload = self.client.request.call_args.args
        self.assertEqual(method, 'POST')
        self.assertEqual(path, f'/zones/{self.zone["id"]}/dns_records')
        self.assertEqual(payload, {'type': 'A', 'name': self.hostname, 'content': '192.168.1.2',
                                  'ttl': 60, 'proxied': False, 'comment': self.marker})

    def test_updates_only_the_owned_record_when_the_lan_address_changes(self):
        with self.context([self.record()]):
            self.assertEqual(self.dns.sync('.', '192.168.1.3')['action'], 'updated')
        self.assertEqual(self.client.request.call_args.args[0], 'PATCH')
        self.assertTrue(self.client.request.call_args.args[1].endswith('/' + 'b' * 32))

    def test_an_unchanged_record_does_not_write_to_cloudflare(self):
        with self.context([self.record()]):
            self.assertEqual(self.dns.sync('.', '192.168.1.2')['action'], 'unchanged')
        self.client.request.assert_not_called()

    def test_dry_run_does_not_write_to_cloudflare(self):
        with self.context([]):
            self.assertEqual(self.dns.sync('.', '192.168.1.2', dry_run=True)['action'], 'would-create')
        self.client.request.assert_not_called()
        self.mode_write.assert_not_called()

    def test_foreign_address_alias_and_https_records_are_never_overwritten(self):
        for kind in ('A', 'AAAA', 'CNAME', 'NS', 'HTTPS', 'SVCB'):
            with self.subTest(kind=kind), self.context([self.record(type=kind, comment='another purpose')]):
                with self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'unowned'):
                    self.dns.sync('.', '192.168.1.2')
        self.client.request.assert_not_called()

    def test_an_ownership_marker_for_another_hostname_is_not_accepted(self):
        with self.context([self.record(comment='managed-by-project-development:dev.other.com')]):
            with self.assertRaises(self.dns.DevelopmentDNSError):
                self.dns.sync('.', '192.168.1.2')
        self.client.request.assert_not_called()

    def test_multiple_owned_addresses_or_an_owned_alias_are_not_silently_repaired(self):
        for records in ([self.record(), self.record(content='192.168.1.3')], [self.record(type='AAAA')]):
            with self.subTest(records=records), self.context(records):
                with self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'conflicting'):
                    self.dns.sync('.', '192.168.1.2')
        self.client.request.assert_not_called()

    def test_unrelated_txt_records_are_preserved(self):
        with self.context([self.record(type='TXT', comment='another purpose')]):
            self.assertEqual(self.dns.sync('.', '192.168.1.2')['action'], 'created')
        self.assertEqual(self.client.request.call_count, 1)

    def test_non_lan_addresses_are_rejected_before_accessing_cloudflare(self):
        for address in ('127.0.0.1', '169.254.1.1', '0.0.0.0', '8.8.8.8', '192.0.2.1', '100.64.0.1', '::1', 'bad'):
            with self.subTest(address=address), patch.object(self.dns, '_context') as context:
                with self.assertRaises(self.dns.DevelopmentDNSError):
                    self.dns.sync('.', address)
                context.assert_not_called()

    def test_credential_check_is_read_only_and_does_not_claim_dns_edit_permissions(self):
        with self.context([self.record()]):
            result = self.dns.check('.')
        self.assertEqual(result['dns_access'], 'readable')
        self.assertEqual(result['record_count'], 1)
        self.client.request.assert_not_called()

    def test_zone_discovery_uses_authorized_hostname_suffixes(self):
        from unittest.mock import Mock
        with patch.object(self.dns, '_read_token', return_value='test-token'):
            client = self.dns._Cloudflare('unused')
        client.request = Mock(side_effect=[{'result': []}, {'result': [self.zone]}])
        self.assertEqual(client.zone(self.hostname), self.zone)
        self.assertIn('name=dev.example.com', client.request.call_args_list[0].args[1])
        self.assertIn('name=example.com', client.request.call_args_list[1].args[1])

    def test_record_pagination_is_complete_and_does_not_match_another_host(self):
        from unittest.mock import Mock
        with patch.object(self.dns, '_read_token', return_value='test-token'):
            client = self.dns._Cloudflare('unused')
        client.request = Mock(side_effect=[
            {'result': [self.record(name='other.example.com')], 'result_info': {'total_pages': 2}},
            {'result': [self.record()], 'result_info': {'total_pages': 2}}])
        self.assertEqual(client.records(self.zone['id'], self.hostname), [self.record()])

    def test_http_errors_never_echo_credential_headers_or_response_bodies(self):
        import io
        from unittest.mock import Mock
        from urllib.error import HTTPError
        with patch.object(self.dns, '_read_token', return_value='test-private-token'):
            client = self.dns._Cloudflare('unused')
        client._opener = Mock()
        client._opener.open.side_effect = HTTPError('https://api.cloudflare.com/client/v4/zones', 403,
                                                   'test-private-token', {}, io.BytesIO(b'test-private-token'))
        with self.assertRaises(self.dns.DevelopmentDNSError) as caught:
            client.request('GET', '/zones')
        self.assertNotIn('test-private-token', str(caught.exception))
        self.assertIn('403', str(caught.exception))

    def test_http_redirects_cannot_forward_the_api_token(self):
        with self.assertRaises(self.dns.DevelopmentDNSError):
            self.dns._NoRedirects().redirect_request(None, None, 302, '', {}, 'https://other.example.com')

    def test_checkout_token_path_ignores_inherited_project_secrets(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.env').write_text('DEV_DNS_TOKEN_FILE=.private/token\n', encoding='utf-8')
            with patch.dict(os.environ, {'DEV_DNS_TOKEN_FILE': 'wrong-project', 'CF_DNS_API_TOKEN': 'never-use'}):
                self.assertEqual(self.dns.token_file(root), root / '.private' / 'token')

    def test_shared_resolver_rejects_a_different_checkout_credential_before_reading(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(self.dns, 'host_token_file', return_value=root / 'host-token'), \
                    patch.object(self.dns, 'token_file', return_value=root / 'project-token'), \
                    patch.object(self.dns, '_read_token') as read:
                with self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'host-wide'):
                    self.dns.prepare_host(root)
                read.assert_not_called()

    def test_shared_token_preflight_checks_permissions_without_network(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'host-token'
            with patch.object(self.dns, 'host_token_file', return_value=path), \
                    patch.object(self.dns, 'token_file', return_value=path), \
                    patch.object(self.dns, '_read_token', return_value='private-test-token') as read, \
                    patch.object(self.dns, '_Cloudflare') as client:
                self.assertEqual(self.dns.prepare_host(directory), path.resolve())
                read.assert_called_once_with(path.resolve())
                client.assert_not_called()

    def test_windows_public_token_acl_is_rejected(self):
        from unittest.mock import Mock
        with patch.object(self.dns.subprocess, 'run', return_value=Mock(returncode=3)):
            with self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'readable only'):
                self.dns._windows_private_file(Path('private-token'))

    def test_windows_acl_inspection_failure_is_distinct_from_public_permissions(self):
        from unittest.mock import Mock
        with patch.object(self.dns.subprocess, 'run', return_value=Mock(returncode=4)):
            with self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'Could not verify'):
                self.dns._windows_private_file(Path('private-token'))

    def test_windows_acl_uses_sids_and_fallback_powershell_ignores_ps7_modules(self):
        import base64
        from unittest.mock import Mock
        with patch.object(self.dns.shutil, 'which', return_value=None), \
                patch.dict(os.environ, {'PSModulePath': 'wrong-version-modules'}), \
                patch.object(self.dns.subprocess, 'run', return_value=Mock(returncode=0)) as run:
            self.dns._windows_private_file(Path('private-token'))
        command = run.call_args.args[0]
        script = base64.b64decode(command[-1]).decode('utf-16-le')
        self.assertIn('GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])', script)
        self.assertNotIn('.Translate(', script)
        self.assertNotIn('PSModulePath', run.call_args.kwargs['env'])

    def test_localhost_checkout_is_rejected_before_token_prompt_or_api(self):
        with TemporaryDirectory() as directory:
            root = Path(directory) / 'Application'
            root.mkdir()
            with patch.object(self.dns, '_Cloudflare') as client, patch.object(self.dns, '_prompt_token') as prompt:
                for command in (self.dns.setup, self.dns.check):
                    with self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'domain you own'):
                        command(root)
                with self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'domain you own'):
                    self.dns.sync(root, '192.168.1.2')
                client.assert_not_called()
                prompt.assert_not_called()
            self.mode_write.assert_not_called()

    def test_setup_enrolls_private_host_token_then_only_checks_the_selected_zone(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'host' / 'cloudflare-token'
            with patch.object(self.dns, '_public_hostname', return_value=self.hostname), \
                    patch.object(self.dns, '_host_token_path', return_value=path), \
                    patch.object(self.dns, '_prompt_token', return_value='private-test-token') as prompt, \
                    patch.object(self.dns, '_restrict_windows_path'), \
                    patch.object(self.dns, '_windows_private_file'), \
                    patch.object(self.dns, 'check', return_value={'hostname': self.hostname, 'dns_access': 'readable'}) as check, \
                    patch.object(self.dns, '_setup_contact') as contact:
                result = self.dns.setup(directory)
            self.assertEqual(path.read_text().strip(), 'private-test-token')
            self.assertEqual(result['credential'], 'enrolled')
            self.assertNotIn('private-test-token', json.dumps(result))
            self.assertEqual(list(path.parent.iterdir()), [path])
            prompt.assert_called_once()
            check.assert_called_once_with(directory, path)
            contact.assert_called_once_with(path)
            self.mode_write.assert_called_once_with(directory)
            if os.name != 'nt':
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_existing_token_is_preserved_and_never_reprompted(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'cloudflare-token'
            path.write_text('existing-test-token')
            path.chmod(0o600)
            with patch.object(self.dns, '_public_hostname', return_value=self.hostname), \
                    patch.object(self.dns, '_host_token_path', return_value=path), \
                    patch.object(self.dns, '_windows_private_file'), \
                    patch.object(self.dns, '_prompt_token') as prompt, \
                    patch.object(self.dns, 'check', return_value={'dns_access': 'readable'}), \
                    patch.object(self.dns, '_setup_contact'):
                self.assertEqual(self.dns.setup(directory)['credential'], 'existing')
            self.assertEqual(path.read_text(), 'existing-test-token')
            prompt.assert_not_called()

    def test_setup_scope_failure_preserves_token_and_does_not_enable_public_mode(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'cloudflare-token'
            path.write_text('existing-test-token')
            path.chmod(0o600)
            with patch.object(self.dns, '_public_hostname', return_value=self.hostname), \
                    patch.object(self.dns, '_host_token_path', return_value=path), \
                    patch.object(self.dns, '_windows_private_file'), \
                    patch.object(self.dns, 'check', side_effect=self.dns.DevelopmentDNSError('Not authorized')):
                with self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'Zone:Read and DNS:Edit'):
                    self.dns.setup(directory)
            self.assertEqual(path.read_text(), 'existing-test-token')
            self.mode_write.assert_not_called()

    def test_token_prompt_refuses_redirected_input_and_getpass_fallback(self):
        import warnings
        with patch.object(self.dns.sys.stdin, 'isatty', return_value=False), \
                patch.object(self.dns.getpass, 'getpass') as prompt:
            with self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'interactive terminal'):
                self.dns._prompt_token()
            prompt.assert_not_called()
        def unmasked(*args, **kwargs):
            warnings.warn('Cannot hide input', self.dns.getpass.GetPassWarning)
            self.fail('Unmasked fallback must not read input')
        with patch.object(self.dns, '_require_interactive'), patch.object(self.dns.getpass, 'getpass', side_effect=unmasked):
            with self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'cannot hide input'):
                self.dns._prompt_token()

    def test_private_enrollment_never_replaces_an_existing_file(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'host' / 'token'
            with patch.object(self.dns, '_restrict_windows_path'):
                self.assertTrue(self.dns._write_private_file(path, 'first-test-token'))
                self.assertFalse(self.dns._write_private_file(path, 'second-test-token'))
            self.assertEqual(path.read_text(), 'first-test-token\n')
            self.assertEqual(list(path.parent.iterdir()), [path])

    @unittest.skipUnless(os.name == 'nt', 'Windows ACL ordering')
    def test_windows_temp_file_is_empty_when_acl_is_restricted(self):
        protected = []
        def protect(path, directory=False):
            if not directory:
                self.assertEqual(path.read_bytes(), b'')
                protected.append(path)
        with TemporaryDirectory() as directory, patch.object(self.dns, '_restrict_windows_path', side_effect=protect):
            self.dns._write_private_file(Path(directory) / 'token', 'private-test-token')
        self.assertEqual(len(protected), 1)

    def test_contact_reuses_saved_value_or_global_git_email(self):
        from unittest.mock import Mock
        with TemporaryDirectory() as directory:
            token = Path(directory) / 'token'
            contact = token.parent / 'acme-email'
            contact.write_text('saved@example.com\n')
            with patch.object(self.dns.subprocess, 'run') as git, patch('builtins.input') as prompt:
                self.dns._setup_contact(token)
                git.assert_not_called()
                prompt.assert_not_called()
            contact.unlink()
            with patch.object(self.dns.subprocess, 'run', return_value=Mock(returncode=0, stdout='global@example.com\n')) as git, \
                    patch.object(self.dns, '_restrict_windows_path'), patch('builtins.input') as prompt:
                self.dns._setup_contact(token)
                self.assertEqual(contact.read_text(), 'global@example.com\n')
                self.assertEqual(git.call_args.args[0], ['git', 'config', '--global', '--get', 'user.email'])
                prompt.assert_not_called()

    def test_public_mode_updates_only_the_exact_root_setting(self):
        with TemporaryDirectory() as directory, patch.object(self.dns, '_restrict_windows_path'):
            path = Path(directory) / '.env'
            original = b'\xef\xbb\xbfSECRET="test=private"\r\n# DEV_TLS_MODE=ignore\r\nOTHER_DEV_TLS_MODE=local\r\nDEV_TLS_MODE=local\r\n'
            path.write_bytes(original)
            self.set_public_mode(directory)
            self.assertEqual(path.read_bytes(), original.replace(b'\nDEV_TLS_MODE=local', b'\nDEV_TLS_MODE=public'))
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_public_mode_refuses_to_overwrite_a_concurrent_env_edit(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / '.env'
            path.write_text('FIRST=value\n')
            def changed_during_write(descriptor):
                path.write_text('FIRST=new-edit\n')
            with patch.object(self.dns, '_restrict_windows_path'), patch.object(self.dns.os, 'fsync', side_effect=changed_during_write):
                with self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'changed during'):
                    self.set_public_mode(directory)
            self.assertEqual(path.read_text(), 'FIRST=new-edit\n')
            self.assertEqual(list(Path(directory).iterdir()), [path])

    @unittest.skipIf(os.name == 'nt', 'Unix permission bits are enforced on Unix hosts')
    def test_unix_world_readable_token_is_rejected(self):
        with TemporaryDirectory() as directory:
            token = Path(directory) / 'token'
            token.write_text('private-test-token', encoding='utf-8')
            token.chmod(0o644)
            with self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'private permissions'):
                self.dns._read_token(token)

    def test_incorrect_mutation_confirmation_is_not_reported_as_success(self):
        self.client.request.side_effect = None
        self.client.request.return_value = {'result': {'proxied': True}}
        with self.context([]), self.assertRaisesRegex(self.dns.DevelopmentDNSError, 'did not confirm'):
            self.dns.sync('.', '192.168.1.2')

    def test_owned_records_repair_proxy_or_ttl_drift(self):
        for change in ({'proxied': True}, {'ttl': 300}):
            with self.subTest(change=change), self.context([self.record(**change)]):
                self.assertEqual(self.dns.sync('.', '192.168.1.2')['action'], 'updated')


class MonitorLanTests(SimpleTestCase):
    def setUp(self):
        # Native Windows locks must never touch a user's live monitor session.
        temporary = TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        local_data = patch.dict(os.environ, {'LOCALAPPDATA': temporary.name})
        local_data.start()
        self.addCleanup(local_data.stop)

    def test_terminal_requests_require_session_token_and_fixed_actions(self):
        from .network import monitor_request
        with TemporaryDirectory() as directory, patch('config.network.monitor_change', return_value='LAN off') as change:
            for request in [[], {}, {'token': 'wrong', 'action': 'on'},
                            {'token': 'session', 'action': 'execute'},
                            {'token': 'session', 'action': 'on', 'project': '../outside'}]:
                with self.assertRaises(ValueError):
                    monitor_request(directory, directory, 'session', request)
            change.assert_not_called()
            result = monitor_request(directory, directory, 'session', {'token': 'session', 'action': 'off', 'project': 'one'})
            self.assertEqual(result, 'LAN off')
            change.assert_called_once_with(directory, directory, 'off', 'one')

    def test_terminal_hit_regions_ignore_colors_and_real_url_links(self):
        from .network import frame_controls
        text = ('  infrastructure \x1b[31m[LAN OFF]\x1b[0m\n'
                '  project \x1b[32m[LAN ON]\x1b[0m \x1b]8;;https://example.local\x1b\\example.local\x1b]8;;\x1b\\\n')
        controls = [{'project': None, 'action': 'on'}, {'project': 'one', 'action': 'off'}]
        regions = frame_controls(text, controls)
        self.assertEqual([(item['row'], item['column'], item['width']) for item in regions], [(0, 17, 9), (1, 10, 8)])
        self.assertEqual(regions[1]['project'], 'one')

    def test_terminal_parser_handles_fragmented_clicks_keyboard_and_ignored_pastes(self):
        from .network import terminal_event
        event, remaining = terminal_event('\x1b[<0;18;2M\t')
        self.assertEqual(event, ('mouse', 0, 17, 1, 'M'))
        self.assertEqual(terminal_event(remaining)[0], ('key', '\t'))
        self.assertEqual(terminal_event('\x1b[<0;18;2m')[0][-1], 'm')
        self.assertEqual(terminal_event('\x1b[<0;18;')[0], None)
        self.assertEqual(terminal_event('\x1b[A')[0], ('key', 'up'))
        self.assertEqual(terminal_event('\x1b[200~l q '), (None, '\x1b[200~l q '))
        self.assertEqual(terminal_event('\x1b[200~l q \x1b[201~q'), (('ignore',), 'q'))

    def test_individual_off_preserves_other_projects_and_remembers_its_choice(self):
        from .network import configure, monitor_change, lan_preferences
        with TemporaryDirectory() as directory:
            roots = {name: Path(directory) / name for name in ('one', 'two')}
            routing = Path(directory) / 'routing'
            for root in roots.values():
                root.mkdir()
                (root / '.env').write_text('DEV_DOMAIN=' + root.name + '.app\n')
                configure(root, 'on', routing)
            with patch('config.network.monitor_projects', return_value=roots), patch('config.network.subprocess.run', return_value=subprocess.CompletedProcess([], 0, '', '')) as command:
                monitor_change(directory, routing, 'off', 'one')
            self.assertFalse((routing / 'one-lan.state').exists())
            self.assertTrue((routing / 'two-lan.state').exists())
            self.assertEqual(lan_preferences(routing), {'default': True, 'projects': {'one': False}})
            self.assertEqual(command.call_count, 1)
            self.assertEqual(command.call_args.kwargs['cwd'], roots['one'])

    @patch('config.network.background_lan_ready', return_value=True)
    def test_default_on_applies_to_new_running_projects_only_and_honors_saved_off(self, _ready):
        from .network import monitor_defaults, atomic_json
        with TemporaryDirectory() as directory:
            roots = {name: Path(directory) / name for name in ('one', 'two')}
            attempted = set()
            with patch('config.network.monitor_projects', return_value=roots), patch('config.network.running_projects', return_value=set(roots)), patch('config.network.monitor_change') as change:
                monitor_defaults(directory, directory, attempted)
                self.assertEqual([call.args[3] for call in change.call_args_list], ['one', 'two'])
                change.reset_mock()
                monitor_defaults(directory, directory, attempted)
                change.assert_not_called()
                attempted.clear()
                atomic_json(Path(directory) / '.lan-preferences.json', {'default': True, 'projects': {'one': False}})
                monitor_defaults(directory, directory, attempted)
                change.assert_called_once_with(directory, directory, 'on', 'two', remember=False)
                change.reset_mock()
                attempted.clear()
                atomic_json(Path(directory) / '.lan-preferences.json', {'default': False, 'projects': {}})
                monitor_defaults(directory, directory, attempted)
                change.assert_not_called()

    @patch('config.network.background_lan_ready', return_value=True)
    def test_failed_default_on_is_not_retried_in_the_background(self, _ready):
        from .network import monitor_defaults
        with TemporaryDirectory() as directory, patch('config.network.monitor_projects', return_value={'one': Path(directory)}), patch('config.network.running_projects', return_value={'one'}), patch('config.network.monitor_change', side_effect=ValueError('Public network')) as change:
            attempted = set()
            monitor_defaults(directory, directory, attempted)
            monitor_defaults(directory, directory, attempted)
            change.assert_called_once()

    def test_master_off_clears_individual_overrides_and_applies_to_future_projects(self):
        from .network import monitor_change, atomic_json, lan_preferences
        with TemporaryDirectory() as directory, patch('config.network.monitor_projects', return_value={}):
            atomic_json(Path(directory) / '.lan-preferences.json', {'default': True, 'projects': {'one': True, 'two': False}})
            monitor_change(directory, directory, 'off')
            self.assertEqual(lan_preferences(directory), {'default': False, 'projects': {}})

    def test_unknown_project_cannot_run_commands_or_change_preferences(self):
        from .network import monitor_change
        with TemporaryDirectory() as directory, patch('config.network.monitor_projects', return_value={}), patch('config.network.subprocess.run') as command:
            with self.assertRaisesRegex(ValueError, 'Unknown project'):
                monitor_change(directory, directory, 'on', 'outside')
            command.assert_not_called()
            self.assertFalse((Path(directory) / '.lan-preferences.json').exists())

    def test_multiple_monitors_cannot_update_lan_concurrently(self):
        from .network import monitor_update_lock
        with TemporaryDirectory() as directory:
            with monitor_update_lock(directory):
                with self.assertRaisesRegex(ValueError, 'Another monitor'):
                    with monitor_update_lock(directory):
                        self.fail('A second writer acquired the LAN lock')
            with monitor_update_lock(directory):
                pass

    def test_workspace_discovery_preserves_resource_namespace_and_rejects_collisions(self):
        from .network import monitor_projects
        with TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('One.app', 'Two.app'):
                checkout = root / name
                (checkout / 'backend').mkdir(parents=True)
                (checkout / 'dev.sh').touch()
                (checkout / 'backend/project.py').write_text('')
            (root / 'One.app/backend/project.py').write_text("DEV_RESOURCE_NAMESPACE = 'existing'\n")
            self.assertEqual(set(monitor_projects(root / 'One.app')), {'existing', 'twoapp'})
            (root / 'Two.app/backend/project.py').write_text("DEV_RESOURCE_NAMESPACE = 'existing'\n")
            with self.assertRaisesRegex(ValueError, 'share a resource namespace'):
                monitor_projects(root / 'One.app')

    @unittest.skipUnless(os.name == 'nt', 'Windows network category guard')
    def test_automatic_public_network_sharing_is_rejected_before_any_project_command(self):
        from .network import monitor_change
        with TemporaryDirectory() as directory, patch('config.network.monitor_projects', return_value={'app': Path(directory)}), patch('config.network.subprocess.check_output', side_effect=['app\n', '']), patch('config.network.subprocess.run') as command:
            with self.assertRaisesRegex(ValueError, 'Public'):
                monitor_change(directory, directory, 'on', remember=False)
            command.assert_not_called()

    @unittest.skipUnless(os.name == 'nt', 'Windows explicit Public session')
    def test_explicit_public_toggle_requests_only_a_scoped_session(self):
        import base64
        from .network import monitor_change
        with TemporaryDirectory() as directory, patch('config.network.monitor_projects', return_value={'app': Path(directory)}), patch('config.network.subprocess.check_output', side_effect=['app\n', '']), patch('config.network.subprocess.run', return_value=subprocess.CompletedProcess([], 0, '', '')) as command:
            message = monitor_change(directory, directory, 'on', 'app')
            invocation = base64.b64decode(command.call_args.args[0][-1]).decode('utf-16-le')
            self.assertIn('lan on --allow-public;', invocation)
            self.assertNotIn('Set-NetConnectionProfile', invocation)
            self.assertIn('current network only', message)

    def test_failed_enable_rolls_back_new_opt_ins_and_never_runs_other_workspaces(self):
        from .network import monitor_change
        with TemporaryDirectory() as directory:
            roots = {name: Path(directory) / name for name in ('one', 'two')}
            for root in roots.values():
                root.mkdir()
            inventories = ['one\ntwo\nunrelated\n'] + (['3'] if os.name == 'nt' else [])
            results = [subprocess.CompletedProcess([], code, '', 'failed' if code else '') for code in (0, 1, 0, 0)]
            with patch('config.network.monitor_projects', return_value=roots), patch('config.network.subprocess.check_output', side_effect=inventories), patch('config.network.subprocess.run', side_effect=results) as command:
                with self.assertRaisesRegex(ValueError, 'failed'):
                    monitor_change(directory, directory, 'on')
            self.assertEqual(command.call_count, 4)
            self.assertEqual([call.kwargs['cwd'].name for call in command.call_args_list], ['one', 'two', 'one', 'two'])

    def test_timeout_revokes_all_new_opt_ins_before_any_launcher_cleanup(self):
        from .network import configure, monitor_change, enabled_hosts
        with TemporaryDirectory() as directory:
            roots = {name: Path(directory) / name for name in ('one', 'two')}
            routing = Path(directory) / 'routing'
            for root in roots.values():
                root.mkdir()
                (root / '.env').write_text('DEV_DOMAIN=' + root.name + '.app\n')
            calls = []
            def launcher(command, **options):
                calls.append(options)
                self.assertEqual(options['timeout'], 180)
                if len(calls) <= 2:
                    configure(options['cwd'], 'on', routing)
                    if len(calls) == 2:
                        raise subprocess.TimeoutExpired(command, 180)
                else:
                    self.assertEqual(enabled_hosts(routing), set())
                return subprocess.CompletedProcess(command, 0, '', '')
            inventories = ['one\ntwo\n'] + (['3'] if os.name == 'nt' else [])
            with patch('config.network.monitor_projects', return_value=roots), \
                    patch('config.network.subprocess.check_output', side_effect=inventories), \
                    patch('config.network.subprocess.run', side_effect=launcher):
                with self.assertRaisesRegex(ValueError, 'timed out after 180 seconds'):
                    monitor_change(directory, routing, 'on')
            self.assertEqual(len(calls), 4)
            self.assertEqual(enabled_hosts(routing), set())

    def test_off_revokes_all_projects_even_when_a_launcher_fails(self):
        from .network import configure, monitor_change, enabled_hosts
        with TemporaryDirectory() as directory:
            roots = {name: Path(directory) / name for name in ('one', 'two')}
            routing = Path(directory) / 'routing'
            for root in roots.values():
                root.mkdir()
                (root / '.env').write_text('DEV_DOMAIN=' + root.name + '.app\n')
                configure(root, 'on', routing)
            with patch('config.network.monitor_projects', return_value=roots), patch('config.network.subprocess.check_output', return_value='one\ntwo\n'), patch('config.network.subprocess.run', return_value=subprocess.CompletedProcess([], 1, '', 'failed')):
                with self.assertRaisesRegex(ValueError, 'failed'):
                    monitor_change(directory, routing, 'off')
            self.assertEqual(enabled_hosts(routing), set())
            self.assertEqual(list(routing.glob('*-lan.yml')), [])


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
            self.assertTrue(settings.MEDIA_URL.startswith(('http://', 'https://', '/')))

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
