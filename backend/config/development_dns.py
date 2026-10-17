"""Publish an owned development hostname to the current private LAN address.

Run: python development_dns.py PROJECT_ROOT setup|check|sync [--address PRIVATE_IPV4]
Credentials are read from a private host file, never from another project's
inherited environment. Only the canonical development record may be changed.
"""
import argparse
import base64
import getpass
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import warnings
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

if __package__:
    from .project_config import development_hostname, development_hostname_for_domain, environment_values
else:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from config.project_config import development_hostname, development_hostname_for_domain, environment_values


class DevelopmentDNSError(ValueError):
    """An actionable DNS error whose message never contains credential material."""


def host_token_file():
    """The single host credential used by shared Traefik, across all checkouts."""
    if os.name == 'nt':
        local = os.environ.get('LOCALAPPDATA')
        return (Path(local) if local else Path.home() / 'AppData' / 'Local') / 'ProjectDevelopment' / 'cloudflare-token'
    return Path.home() / '.config' / 'project-development' / 'cloudflare-token'


def token_file(root):
    """Resolve this checkout's credential-file reference without importing apps.

    Standalone DNS commands can explicitly select another private token. A
    launcher configuring shared Traefik must instead require the host token,
    preventing another checkout from changing the shared resolver credential.
    """
    configured = environment_values(root).get('DEV_DNS_TOKEN_FILE', '').strip()
    if configured:
        path = Path(configured).expanduser()
        return path if path.is_absolute() else Path(root).resolve() / path
    return host_token_file()


def _powershell(script):
    shell = shutil.which('pwsh.exe') or shutil.which('powershell.exe') or 'powershell.exe'
    environment = dict(os.environ)
    if Path(shell).name.lower() == 'powershell.exe':
        # PS7 module paths can prevent Windows PowerShell from loading Get-Acl.
        environment = {key: value for key, value in environment.items() if key.lower() != 'psmodulepath'}
    command = base64.b64encode(script.encode('utf-16-le')).decode('ascii')
    return subprocess.run(
        [shell, '-NoProfile', '-NonInteractive', '-EncodedCommand', command], env=environment,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15,
        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0), check=False)


def _windows_private_file(path):
    # SID checks avoid localized account names. A broader inherited Read ACL
    # also fails; do not silently change permissions on a credential file.
    encoded_path = base64.b64encode(str(path).encode('utf-8')).decode('ascii')
    script = r"""
$ErrorActionPreference = 'Stop'
try {
    $path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('PATH_BASE64'))
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowed = @($current, 'S-1-5-18', 'S-1-5-32-544', 'S-1-3-0')
    $acl = Get-Acl -LiteralPath $path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $allowed) { exit 3 }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        $sid = $rule.IdentityReference.Value
        $rights = [long]$rule.FileSystemRights
        # Read/write data, delete, permissions and ownership are all sensitive.
        if (($rights -band 852311) -and ($sid -notin $allowed)) { exit 3 }
    }
    exit 0
} catch { exit 4 }
""".replace('PATH_BASE64', encoded_path)
    try:
        result = _powershell(script)
    except (OSError, subprocess.SubprocessError) as error:
        raise DevelopmentDNSError('Could not verify DNS token-file permissions on Windows.') from error
    if result.returncode == 3:
        raise DevelopmentDNSError('The DNS token file must be readable only by your Windows account, SYSTEM, and Administrators.')
    if result.returncode:
        raise DevelopmentDNSError('Could not verify DNS token-file permissions on Windows; check that PowerShell can read its owner and access rules.')


def _read_token(path):
    try:
        path = Path(path).expanduser().resolve(strict=True)
        if os.name == 'nt':
            _windows_private_file(path)
        with path.open('r', encoding='utf-8-sig') as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode):
                raise DevelopmentDNSError('The DNS token path must refer to a regular private file.')
            if os.name != 'nt' and (metadata.st_mode & 0o077 or metadata.st_uid not in (os.geteuid(), 0)):
                raise DevelopmentDNSError('The DNS token file needs private permissions (chmod 600) and must belong to your account or root.')
            value = stream.read(4097).strip()
    except DevelopmentDNSError:
        raise
    except (OSError, UnicodeError) as error:
        raise DevelopmentDNSError('Create the private Cloudflare token file or set DEV_DNS_TOKEN_FILE in this project\'s root .env.') from error
    if not value or len(value) > 4096 or not re.fullmatch(r'[A-Za-z0-9._~-]+', value):
        raise DevelopmentDNSError('The DNS token file must contain only the Cloudflare API token.')
    return value


def _host_token_path(root):
    """Reject per-project overrides of the shared host credential."""
    shared = host_token_file().expanduser().resolve()
    configured = token_file(root).expanduser().resolve()
    if configured != shared:
        try:
            identical = configured.samefile(shared)
        except OSError:
            identical = False
        if not identical:
            raise DevelopmentDNSError('Shared Traefik requires the host-wide Cloudflare token file; remove the differing DEV_DNS_TOKEN_FILE override.')
    return shared


def recover_host_token():
    """Restore a missing Windows host token from the WSL copy made by an earlier sync.

    Every successful sync mirrors the host token into WSL. If the Windows copy
    is later lost, reuse that private copy instead of asking for a new token.
    The token travels only over a pipe, never through arguments or logs.
    """
    path = host_token_file()
    if os.name != 'nt' or path.exists():
        return False
    try:
        result = subprocess.run(['wsl.exe', '-d', 'Ubuntu', '--cd', '/', '--', 'sh', '-c',
                                 'cat "$HOME/.config/project-development/cloudflare-token" 2>/dev/null'],
                                capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return False
    value = result.stdout.decode('utf-8', 'replace').strip() if result.returncode == 0 else ''
    if not value or len(value) > 4096 or not re.fullmatch(r'[A-Za-z0-9._~-]+', value):
        return False
    restored = _write_private_file(path, value)
    if restored:
        print('Restored the host Cloudflare token from WSL.', file=sys.stderr)
    return restored


def prepare_host(root):
    """Validate the one shared resolver credential locally; return only its path."""
    shared = _host_token_path(root)
    recover_host_token()
    _read_token(shared)
    return shared


def _restrict_windows_path(path, directory=False):
    """Apply a private ACL to an empty file/directory before storing a secret."""
    encoded_path = base64.b64encode(str(path).encode('utf-8')).decode('ascii')
    script = r"""
$ErrorActionPreference = 'Stop'
try {
    $path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('PATH_BASE64'))
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) {
        $acl.RemoveAccessRuleSpecific($rule)
    }
    foreach ($value in @($current.Value, 'S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object Security.Principal.SecurityIdentifier($value)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'INHERITANCE', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $item = Get-Item -LiteralPath $path
    # Persist only modified access rules. Set-Acl can request audit privileges
    # even though this operation needs only this account's normal file rights.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [IO.FileSystemAclExtensions]::SetAccessControl($item, $acl)
    } else {
        $item.SetAccessControl($acl)
    }
    exit 0
} catch { exit 4 }
""".replace('PATH_BASE64', encoded_path).replace(
        'INHERITANCE', 'ContainerInherit, ObjectInherit' if directory else 'None')
    try:
        result = _powershell(script)
    except (OSError, subprocess.SubprocessError) as error:
        raise DevelopmentDNSError('Could not secure the private DNS credential location on Windows.') from error
    if result.returncode:
        raise DevelopmentDNSError('Could not secure the private DNS credential location on Windows; no credential was written.')
    _windows_private_file(path)


def _write_private_file(path, value, replace=False):
    """Publish a complete owner-private file; default to preserving any winner."""
    path = Path(path)
    temporary = None
    descriptor = None
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        metadata = path.parent.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or (
                getattr(metadata, 'st_file_attributes', 0) & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0)):
            raise DevelopmentDNSError('The private DNS credential directory must not be a symbolic link or reparse point.')
        if os.name == 'nt':
            _restrict_windows_path(path.parent, directory=True)
        else:
            if metadata.st_uid not in (os.geteuid(), 0):
                raise DevelopmentDNSError('The private DNS credential directory must belong to your account or root.')
            path.parent.chmod(0o700)
        descriptor, name = tempfile.mkstemp(prefix='.' + path.name + '-', suffix='.pending', dir=path.parent)
        temporary = Path(name)
        if os.name == 'nt':
            _restrict_windows_path(temporary)
        else:
            os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, 'w', encoding='utf-8', newline='\n') as stream:
            descriptor = None
            stream.write(value + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            os.replace(temporary, path)
        else:
            try:
                # A same-directory hard link publishes atomically without ever
                # replacing a credential enrolled concurrently by another CLI.
                os.link(temporary, path)
            except FileExistsError:
                return False
        return True
    except DevelopmentDNSError:
        raise
    except OSError as error:
        raise DevelopmentDNSError('Could not save the private host DNS configuration; check directory access and free disk space.') from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _require_interactive():
    if not sys.stdin.isatty() or not sys.stderr.isatty():
        raise DevelopmentDNSError('Run dev.sh lan setup or dev.ps1 lan setup in an interactive terminal; credentials are never accepted through redirected input.')


def _prompt_token():
    _require_interactive()
    try:
        # getpass otherwise falls back to visible stdin on an unsupported
        # terminal. Turn its warning into an error before that fallback reads.
        with warnings.catch_warnings():
            warnings.simplefilter('error', getpass.GetPassWarning)
            value = getpass.getpass('Cloudflare API token (hidden): ', stream=sys.stderr).strip()
    except (getpass.GetPassWarning, EOFError, KeyboardInterrupt) as error:
        raise DevelopmentDNSError('DNS setup was canceled or this terminal cannot hide input; no credential was saved.') from error
    if not value or len(value) > 4096 or not re.fullmatch(r'[A-Za-z0-9._~-]+', value):
        raise DevelopmentDNSError('Enter only the Cloudflare API token; no credential was saved.')
    return value


def _valid_email(value):
    return bool(len(value) <= 254 and re.fullmatch(
        r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}", value)
        and '..' not in value and not value.startswith('.'))


def _setup_contact(token_path):
    path = token_path.parent / 'acme-email'
    try:
        value = path.read_text(encoding='utf-8-sig').strip() if path.is_file() else ''
    except (OSError, UnicodeError) as error:
        raise DevelopmentDNSError('Could not read the private host acme-email file.') from error
    if _valid_email(value):
        return
    try:
        result = subprocess.run(['git', 'config', '--global', '--get', 'user.email'],
                                capture_output=True, text=True, timeout=10, check=False)
        value = result.stdout.strip() if result.returncode == 0 else ''
    except (OSError, subprocess.SubprocessError):
        value = ''
    if _valid_email(value):
        print('Trusted HTTPS will use the global Git email for certificate registration.', file=sys.stderr)
    else:
        _require_interactive()
        print('Certificate renewal contact email: ', end='', file=sys.stderr, flush=True)
        try:
            value = input().strip()
        except (EOFError, KeyboardInterrupt) as error:
            raise DevelopmentDNSError('Certificate contact setup was canceled; rerun lan setup to finish.') from error
        if not _valid_email(value):
            raise DevelopmentDNSError('Enter a valid certificate contact email, or save it in the private host acme-email file.')
    _write_private_file(path, value, replace=True)


def set_public_mode(root):
    """Persist one explicit TLS choice without replacing other project inputs."""
    path = Path(root).resolve() / '.env'
    if path.is_symlink():
        raise DevelopmentDNSError('Cannot update TLS mode through a symbolic-link .env file.')
    original = path.read_bytes() if path.exists() else None
    content = original.decode('utf-8-sig') if original is not None else ''
    newline = '\r\n' if '\r\n' in content else '\n'
    pattern = r'(?m)^[ \t]*(?:export[ \t]+)?DEV_TLS_MODE[ \t]*=[^\r\n]*'
    if re.search(pattern, content):
        updated = re.sub(pattern, 'DEV_TLS_MODE=public', content)
    else:
        updated = content + (newline if content and not content.endswith(('\n', '\r')) else '') + 'DEV_TLS_MODE=public' + newline
    encoded = updated.encode('utf-8-sig' if original and original.startswith(b'\xef\xbb\xbf') else 'utf-8')
    if encoded == original:
        return
    descriptor, temporary_name = tempfile.mkstemp(prefix='.env.lan-', suffix='.pending', dir=path.parent)
    temporary = Path(temporary_name)
    try:
        if os.name == 'nt':
            _restrict_windows_path(temporary)
        else:
            os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            descriptor = None
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        if (path.read_bytes() if path.exists() else None) != original:
            raise DevelopmentDNSError('The root .env changed during DNS setup; retry to save DEV_TLS_MODE without losing edits.')
        os.replace(temporary, path)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def _public_hostname(root):
    hostname = development_hostname(root)
    try:
        if not hostname.startswith('dev.') or development_hostname_for_domain(hostname[4:]) != hostname:
            raise ValueError('Invalid public hostname')
    except ValueError as error:
        raise DevelopmentDNSError('LAN with trusted HTTPS needs a domain you own; set DEV_DOMAIN in root .env or backend/project.py. Computer-only startup needs no DNS setup.') from error
    return hostname


def setup(root):
    """Enroll once per computer, then verify only this project's DNS read access."""
    hostname = _public_hostname(root)
    path = _host_token_path(root)
    enrolled = False
    recover_host_token()
    if not path.exists():
        print('Create a Cloudflare API token with Zone:Read and DNS:Edit for your project domains. '
              'The same private host token is reused by every checkout.', file=sys.stderr)
        enrolled = _write_private_file(path, _prompt_token())
    _read_token(path)  # Existing credentials are checked, never silently replaced.
    try:
        result = check(root, path)
    except DevelopmentDNSError as error:
        raise DevelopmentDNSError(f'{error} Ensure the host token includes the active zone owning {hostname} '
                                  'with Zone:Read and DNS:Edit. The saved credential was preserved.') from None
    _setup_contact(path)
    set_public_mode(root)
    return {**result, 'credential': 'enrolled' if enrolled else 'existing', 'contact': 'configured'}


class _NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        # Never forward an Authorization header to an unexpected redirect host.
        raise DevelopmentDNSError('The Cloudflare API returned an unexpected redirect.')


class _Cloudflare:
    def __init__(self, path):
        self._token = _read_token(path)
        self._opener = build_opener(_NoRedirects())

    def request(self, method, path, payload=None):
        request = Request('https://api.cloudflare.com/client/v4' + path,
                          data=None if payload is None else json.dumps(payload).encode('utf-8'),
                          headers={'Authorization': 'Bearer ' + self._token,
                                   'Content-Type': 'application/json',
                                   'User-Agent': 'project-development-dns'}, method=method)
        try:
            with self._opener.open(request, timeout=20) as response:
                raw = response.read(1048577)
            if len(raw) > 1048576:
                raise DevelopmentDNSError('The Cloudflare API response exceeded its expected size.')
            result = json.loads(raw)
        except HTTPError as error:
            # Cloudflare error messages and HTTP bodies can echo request data.
            # Numeric status is sufficient and never reveals the token/header.
            status = error.code
            error.close()
            raise DevelopmentDNSError(f'Cloudflare DNS request failed (HTTP {status}); check token validity and zone permissions.') from None
        except (URLError, TimeoutError, OSError) as error:
            raise DevelopmentDNSError('Could not reach the Cloudflare DNS API securely; check internet connectivity.') from error
        except (ValueError, UnicodeError) as error:
            if isinstance(error, DevelopmentDNSError):
                raise
            raise DevelopmentDNSError('The Cloudflare DNS API returned an invalid response.') from error
        if not isinstance(result, dict) or result.get('success') is not True:
            raise DevelopmentDNSError('Cloudflare rejected the DNS request; check token validity and zone permissions.')
        return result

    def zone(self, hostname):
        labels = hostname.split('.')
        for offset in range(len(labels) - 1):
            candidate = '.'.join(labels[offset:])
            response = self.request('GET', '/zones?' + urlencode({'name': candidate, 'status': 'active', 'per_page': 50}))
            zones = response.get('result')
            if not isinstance(zones, list):
                raise DevelopmentDNSError('Cloudflare returned an invalid zone list.')
            found = [zone for zone in zones if isinstance(zone, dict) and zone.get('name') == candidate
                     and zone.get('status') == 'active' and re.fullmatch(r'[a-fA-F0-9]{32}', str(zone.get('id', '')))]
            if len(found) == 1:
                return found[0]
            if len(found) > 1:
                raise DevelopmentDNSError('Cloudflare returned multiple matching development DNS zones.')
        raise DevelopmentDNSError(f'No active authorized Cloudflare zone owns {hostname}; grant this zone Zone:Read and DNS:Edit access.')

    def records(self, zone_id, hostname):
        records = []
        for page in range(1, 101):
            response = self.request('GET', f'/zones/{zone_id}/dns_records?' + urlencode(
                {'name': hostname, 'page': page, 'per_page': 100}))
            items = response.get('result')
            if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
                raise DevelopmentDNSError('Cloudflare returned an invalid DNS-record list.')
            if any(not isinstance(item.get('name'), str) for item in items):
                raise DevelopmentDNSError('Cloudflare returned a DNS record without a valid hostname.')
            records.extend(item for item in items if item['name'].lower().rstrip('.') == hostname)
            information = response.get('result_info', {})
            if not isinstance(information, dict):
                raise DevelopmentDNSError('Cloudflare returned invalid DNS-record pagination.')
            pages = information.get('total_pages', 1)
            if not isinstance(pages, int) or pages < 0:
                raise DevelopmentDNSError('Cloudflare returned invalid DNS-record pagination.')
            if page >= pages:
                return records
        raise DevelopmentDNSError('The development hostname has too many DNS records to update safely.')


def _context(root, token_path):
    hostname = _public_hostname(root)
    client = _Cloudflare(token_path if token_path is not None else token_file(root))
    zone = client.zone(hostname)
    return hostname, client, zone, client.records(zone['id'], hostname)


def check(root, token_path=None):
    """Authenticate and verify zone/DNS read access without writing a record.

    DNS:Edit is required for sync; a successful read alone cannot prove that
    permission, so this result deliberately does not claim write access.
    """
    hostname, _, zone, records = _context(root, token_path)
    return {'hostname': hostname, 'zone': zone['name'], 'dns_access': 'readable',
            'record_count': len(records)}


def sync(root, address, token_path=None, dry_run=False):
    """Upsert only the owned A record; keep DNS independent of ingress revocation."""
    try:
        ip = ipaddress.IPv4Address(address)
    except ipaddress.AddressValueError as error:
        raise DevelopmentDNSError('Choose the current LAN interface\'s private IPv4 address.') from error
    # Explicit RFC1918 networks exclude loopback, link-local, documentation and
    # unspecified addresses that Python versions may also classify as private.
    if not any(ip in ipaddress.IPv4Network(network) for network in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')):
        raise DevelopmentDNSError('Development DNS may point only to a private LAN IPv4 address.')
    hostname, client, zone, records = _context(root, token_path)
    marker = 'managed-by-project-development:' + hostname
    address_records = [record for record in records if record.get('type') in ('A', 'AAAA', 'CNAME', 'NS', 'HTTPS', 'SVCB')]
    if any(record.get('comment') != marker for record in address_records):
        raise DevelopmentDNSError(f'{hostname} already has an unowned address, alias or routing record; no DNS records were changed.')
    if any(record.get('type') != 'A' for record in address_records) or len(address_records) > 1:
        raise DevelopmentDNSError(f'{hostname} has conflicting DNS records; expected at most one owned A record. No DNS records were changed.')
    current = address_records[0] if address_records else None
    result = {'hostname': hostname, 'zone': zone['name'], 'address': str(ip), 'ttl': 60, 'proxied': False}
    if current and current.get('content') == str(ip) and current.get('proxied') is False and current.get('ttl') == 60:
        if not dry_run:
            set_public_mode(root)
        return {**result, 'action': 'unchanged'}
    action = 'update' if current else 'create'
    if dry_run:
        return {**result, 'action': 'would-' + action}
    payload = {'type': 'A', 'name': hostname, 'content': str(ip), 'ttl': 60,
               'proxied': False, 'comment': marker}
    path = f'/zones/{zone["id"]}/dns_records'
    if current:
        if not re.fullmatch(r'[a-fA-F0-9]{32}', str(current.get('id', ''))):
            raise DevelopmentDNSError('Cloudflare returned an invalid owned DNS-record identifier.')
        path += '/' + current['id']
    response = client.request('PATCH' if current else 'POST', path, payload)
    saved = response.get('result', {})
    if not isinstance(saved, dict) or any(saved.get(key) != value for key, value in payload.items()):
        raise DevelopmentDNSError('Cloudflare did not confirm the requested DNS-only development record; retry a read check before enabling LAN.')
    set_public_mode(root)
    return {**result, 'action': action + 'd' if action == 'update' else 'created'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root')
    parser.add_argument('action', choices=['setup', 'check', 'sync', 'token-path'])
    parser.add_argument('--address')
    parser.add_argument('--token-file')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if args.action == 'sync' and not args.address:
        parser.error('sync requires --address PRIVATE_IPV4')
    if args.action != 'sync' and (args.address or args.dry_run):
        parser.error('--address and --dry-run apply only to sync')
    if args.action in ('setup', 'token-path') and args.token_file:
        parser.error(f'{args.action} uses the host-wide credential; --token-file cannot override it')
    try:
        if args.action == 'token-path':
            print(prepare_host(args.root))
            return 0
        result = (setup(args.root) if args.action == 'setup' else
                  check(args.root, args.token_file) if args.action == 'check' else
                  sync(args.root, args.address, args.token_file, args.dry_run))
    except (DevelopmentDNSError, OSError, ValueError) as error:
        print(f'Development DNS: {error}', file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
