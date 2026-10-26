"""Controlled LAN HTTPS ingress; no app ports or data stores exposed.

Public DNS and ACME certificates serve dev.<domain> without device setup.
The LAN entrypoint has routes only for enabled projects; computer-only routes
use separate loopback listeners. Network changes revoke the sharing session.
"""
import argparse
import base64
from contextlib import contextmanager
import secrets
import ipaddress
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import unicodedata
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import textwrap
import tempfile
import time


def atomic_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.pending')
    temporary.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
    os.replace(temporary, path)


def lan_routes(project, host, relays=('127.0.0.1/32', '::1/128')):
    """Never reuse a local/tunnel entrypoint or create a hostless fallback."""
    routers = {}
    for kind, prefix in [('frontend', ''), ('api', '/api'), ('admin', '/admin'),
                         ('static', '/static'), ('media', '/media')]:
        route = {'entryPoints': ['lan'], 'rule': f'Host(`{host}`)',
                 'service': f'{project}-{"frontend" if kind == "frontend" else "backend"}@docker',
                 'priority': 10 if kind == 'frontend' else 100, 'tls': {'certResolver': 'dev'}}
        route['middlewares'] = [f'{project}-lan-relay']
        if prefix:
            route['rule'] += f' && (Path(`{prefix}`) || PathPrefix(`{prefix}/`))'
        if kind == 'api':
            route['middlewares'].append(f'{project}-strip-api@docker')
        routers[f'{project}-lan-{kind}'] = route
    return {'http': {'routers': routers, 'middlewares': {
        f'{project}-lan-relay': {'ipAllowList': {'sourceRange': list(relays)}}}}}


def discovered_routes(project, host):
    """Include project-owned realtime/optional routes without knowing their apps."""
    ids = subprocess.check_output(['podman', 'ps', '-q', '--filter',
                                   f'label=com.docker.compose.project={project}'], text=True).split()
    if not ids:
        raise ValueError('Start this project before enabling LAN access')
    containers = json.loads(subprocess.check_output(['podman', 'inspect', *ids], text=True))
    routes = {}
    for container in containers:
        labels = container.get('Config', {}).get('Labels', {})
        for key, rule in labels.items():
            if not key.startswith('traefik.http.routers.') or not key.endswith('.rule'):
                continue
            router = key[len('traefik.http.routers.'):-len('.rule')]
            prefix = 'traefik.http.routers.' + router + '.'
            if f'Host(`{host}`)' not in rule or labels.get(prefix + 'entrypoints') != 'websecure':
                continue
            service = labels.get(prefix + 'service')
            if not service:
                services = [k[len('traefik.http.services.'):].split('.')[0] for k in labels
                            if k.startswith('traefik.http.services.') and k.endswith('.loadbalancer.server.port')]
                if len(set(services)) != 1:
                    raise ValueError('Optional LAN router must declare its service explicitly')
                service = services[0]
            # Project-owned expressions may contain OR branches. Keep every
            # cloned branch inside this project's exact hostname boundary.
            route = {'entryPoints': ['lan'], 'rule': f'Host(`{host}`) && ({rule})',
                     'service': service if '@' in service else service + '@docker',
                     'priority': int(labels.get(prefix + 'priority', '10')), 'tls': {'certResolver': 'dev'},
                     'middlewares': [f'{project}-lan-relay']}
            for item in labels.get(prefix + 'middlewares', '').split(','):
                if item:
                    route['middlewares'].append(item if '@' in item else item + '@docker')
            routes[router + '-lan'] = route
    if not routes:
        raise ValueError('Restart the project with its canonical dev hostname before enabling LAN')
    return routes


def remove_lan_file(path):
    # Windows may briefly hold a state file while a relay checks it. Revocation
    # must survive that read rather than failing the user's off command.
    for attempt in range(20):
        try:
            Path(path).unlink(missing_ok=True)
            return
        except PermissionError as error:
            if getattr(error, 'winerror', None) not in (32, 33) or attempt == 19:
                raise
            time.sleep(0.01)


def configure(root, action, directory, relays=('127.0.0.1/32', '::1/128'), discover=False):
    from config.project_config import development_hostname, resource_namespace
    project = resource_namespace(root)
    directory = Path(directory)
    route = directory / f'{project}-lan.yml'
    state = directory / f'{project}-lan.state'
    # Always revoke first, even if the project domain was removed or mistyped.
    if action == 'off':
        remove_lan_file(state)
        remove_lan_file(route)
    try:
        host = development_hostname(root)
    except (ValueError, OSError):
        if action != 'off':
            raise
        return {'host': '', 'enabled': False, 'url': str(Path(root).name)}
    if action == 'on':
        from config.project_config import development_hostname_for_domain
        if development_hostname_for_domain(host.removeprefix('dev.')) != host:
            raise ValueError('LAN HTTPS requires an owned development domain; local-only projects remain available on this computer')
        config = lan_routes(project, host, relays)
        if discover:
            config['http']['routers'] = discovered_routes(project, host)
        atomic_json(route, config)
        atomic_json(state, {'host': host, 'checkout': str(Path(root).resolve())})
    return {'host': host, 'enabled': state.exists(), 'url': f'https://{host}'}


def enabled_hosts(directory):
    """Hosts opted in to LAN sharing.

    Raises OSError when the state directory cannot be read right now (for
    example the \\\\wsl.localhost share stalling after sleep), so callers can
    tell "nothing is shared" apart from "could not check". Path.glob would
    silently return nothing in that case on newer Python versions.
    """
    result = set()
    with os.scandir(directory) as entries:
        names = [entry.name for entry in entries if entry.name.endswith('-lan.state')]
    for name in names:
        try:
            value = json.loads((Path(directory) / name).read_text(encoding='utf-8'))
        except FileNotFoundError:
            continue  # revoked while listing
        except ValueError:
            continue
        if not isinstance(value, dict):
            continue
        host = value.get('host')
        # A stale .local state must never re-enable an old alias.
        from config.project_config import development_hostname_for_domain
        try:
            if isinstance(host, str) and host.startswith('dev.') and development_hostname_for_domain(host[4:]) == host:
                result.add(host)
        except (ValueError, KeyError):
            continue
    return result


def network_signature(address, allow_public=False):
    """Windows Wi-Fi/profile changes revoke the current sharing session."""
    if os.name != 'nt':
        # Unix currently relies on the bound interface/subnet and explicit off;
        # it cannot detect a Wi-Fi change that preserves the same private IP.
        return None
    # A manual Public session remains pinned to this exact interface/network.
    # Report (not throw) an untrusted network so it is told apart from a
    # transient check failure and revoked immediately.
    guard = '' if allow_public else "if($p.NetworkCategory -eq 'Public'){'untrusted'; exit 0}; "
    # address has already been validated as an IPv4 literal, never shell input.
    command = (f"$a=Get-NetIPAddress -IPAddress '{address}' -AddressFamily IPv4 -ErrorAction Stop; "
               "$p=Get-NetConnectionProfile -InterfaceIndex $a.InterfaceIndex -ErrorAction Stop; "
               + guard +
               "$g=Get-NetRoute -InterfaceIndex $a.InterfaceIndex -DestinationPrefix '0.0.0.0/0' "
               "-ErrorAction Stop | Select-Object -First 1 -ExpandProperty NextHop; "
               "@{name=$p.Name;index=$a.InterfaceIndex;category=[string]$p.NetworkCategory;prefix=$a.PrefixLength;gateway=$g} | ConvertTo-Json -Compress")
    value = subprocess.check_output(['powershell.exe', '-NoProfile', '-Command', command],
                                    timeout=20, stderr=subprocess.DEVNULL,
                                    creationflags=subprocess.CREATE_NO_WINDOW, text=True)
    if value.strip() == 'untrusted':
        raise UntrustedNetwork('Untrusted network')
    return json.dumps(json.loads(value), sort_keys=True)


class UntrustedNetwork(ValueError):
    """The interface is now on a Public network; never tolerate this as transient."""


def revoke_all(directory):
    for state in Path(directory).glob('*-lan.state'):
        remove_lan_file(state)
        remove_lan_file(state.with_suffix('.yml'))


def local_subnet(address):
    """Use the selected interface's real mask; never assume a /24 network."""
    if sys.platform == 'win32':
        command = f"Get-NetIPAddress -IPAddress '{address}' -AddressFamily IPv4 | Select-Object -First 1 -ExpandProperty PrefixLength"
        prefix = subprocess.check_output(['powershell.exe', '-NoProfile', '-Command', command],
                                         timeout=8, creationflags=subprocess.CREATE_NO_WINDOW, text=True).strip()
        return ipaddress.ip_network(f'{address}/{int(prefix)}', strict=False)
    if sys.platform == 'darwin':
        result = subprocess.check_output(['ifconfig'], text=True)
        match = re.search(r'\binet\s+' + re.escape(address) + r'\s+netmask\s+(0x[0-9a-fA-F]+|[0-9.]+)', result)
        if match:
            mask = match[1]
            if mask.startswith('0x'):
                mask = str(ipaddress.IPv4Address(int(mask, 16)))
            return ipaddress.ip_network(f'{address}/{mask}', strict=False)
    else:
        result = json.loads(subprocess.check_output(['ip', '-j', '-4', 'address', 'show'], text=True))
        for interface in result:
            for item in interface.get('addr_info', []):
                if item.get('local') == address:
                    return ipaddress.ip_network(f'{address}/{item["prefixlen"]}', strict=False)
    raise ValueError('Could not determine the selected interface subnet; specify --network')


def hello_hostname(data):
    """Read SNI from a bounded, complete TLS ClientHello; reject malformed input."""
    try:
        if len(data) < 9 or data[0] != 22 or data[5] != 1:
            return None
        length = int.from_bytes(data[3:5], 'big') + 5
        if length > len(data) or length > 65536:
            return None
        p = 43
        p += 1 + data[p]
        p += 2 + int.from_bytes(data[p:p + 2], 'big')
        p += 1 + data[p]
        end = p + 2 + int.from_bytes(data[p:p + 2], 'big')
        p += 2
        if end > length:
            return None
        while p + 4 <= end:
            kind, size = struct.unpack('!HH', data[p:p + 4])
            p += 4
            if p + size > end:
                return None
            if kind == 0 and size >= 5 and data[p + 2] == 0:
                n = int.from_bytes(data[p + 3:p + 5], 'big')
                if n + 5 > size:
                    return None
                return data[p + 5:p + 5 + n].decode('ascii').lower()
            p += size
    except (IndexError, UnicodeError, struct.error):
        pass
    return None


class Relay(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, *args, **kwargs):
        self._hosts_lock = threading.Lock()
        self._hosts = frozenset()
        self._hosts_until = 0
        # True only when the last read succeeded. A failed read fails closed
        # (no traffic) but is not proof that sharing was turned off.
        self.hosts_confirmed = False
        self._upstream_lock = threading.Lock()
        self._upstream_checked = 0.0
        self.upstream_resolver = None
        super().__init__(*args, **kwargs)

    def allowed_hosts(self):
        """Share one short-lived snapshot across sockets, including WSL UNC reads."""
        if time.monotonic() >= self._hosts_until:
            with self._hosts_lock:
                if time.monotonic() >= self._hosts_until:
                    try:
                        self._hosts = frozenset(enabled_hosts(self.directory))
                        self.hosts_confirmed = True
                    except OSError:
                        self._hosts = frozenset()
                        self.hosts_confirmed = False
                    self._hosts_until = time.monotonic() + 0.25
        return self._hosts

    def connect_upstream(self):
        attempted = self.upstream
        try:
            return socket.create_connection(attempted, timeout=5)
        except OSError:
            if not self.refresh_upstream(attempted):
                raise
            return socket.create_connection(self.upstream, timeout=5)

    def refresh_upstream(self, attempted):
        """Follow the WSL address after WSL restarts instead of relaying to a dead one.

        Returns True when a different upstream is now available to retry.
        """
        if self.upstream_resolver is None:
            return False
        with self._upstream_lock:
            if self.upstream != attempted:
                return True  # another connection already refreshed it
            if time.monotonic() - self._upstream_checked < UPSTREAM_REFRESH_SECONDS:
                return False
            self._upstream_checked = time.monotonic()
            try:
                address = self.upstream_resolver()
            except (OSError, ValueError, subprocess.SubprocessError):
                return False
            if not address or (address, attempted[1]) == attempted:
                return False
            print(f'LAN upstream moved to {address}', file=sys.stderr, flush=True)
            self.upstream = (address, attempted[1])
            return True


UPSTREAM_REFRESH_SECONDS = 15
# Consecutive failed network checks (10 s apart) tolerated before revoking.
# Waking from sleep or a slow PowerShell start must not switch LAN off.
NETWORK_CHECK_FAILURES = 6


def wsl_upstream_address():
    """Current WSL VM address, the same one global Traefik publishes :8443 on."""
    output = subprocess.check_output(['wsl.exe', '-d', 'Ubuntu', '--cd', '/', '--', 'hostname', '-I'],
                                     timeout=15, stderr=subprocess.DEVNULL, text=True, errors='replace',
                                     creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    for token in output.replace('\x00', '').split():
        try:
            if ipaddress.ip_address(token).version == 4:
                return token
        except ValueError:
            continue
    return None


class Forward(socketserver.BaseRequestHandler):
    def handle(self):
        server = self.server
        if ipaddress.ip_address(self.client_address[0]) not in server.network:
            return
        self.request.settimeout(5)
        data = b''
        try:
            while len(data) < 65536:
                block = self.request.recv(4096)
                if not block:
                    return
                data += block
                if len(data) >= 5 and len(data) >= 5 + int.from_bytes(data[3:5], 'big'):
                    break
            host = hello_hostname(data)
            if host not in server.allowed_hosts():
                return
            with server.connect_upstream() as target:
                target.sendall(data)
                self.request.settimeout(2)
                target.settimeout(2)
                peers = [self.request, target]
                while host in server.allowed_hosts():
                    readable, _, _ = select.select(peers, [], [], 0.25)
                    for source in readable:
                        block = source.recv(65536)
                        if not block:
                            return
                        (target if source is self.request else self.request).sendall(block)
        except (OSError, ValueError):
            return


@contextmanager
def listener_readiness(path, address):
    if path:
        atomic_json(path, {'pid': os.getpid(), 'address': address})
    try:
        yield
    finally:
        if path:
            try:
                target = Path(path)
                if json.loads(target.read_text(encoding='utf-8'))['pid'] == os.getpid():
                    target.unlink(missing_ok=True)
            except (OSError, ValueError, KeyError):
                pass


def serve(directory, address, upstream, port=443, network=None, allow_public=False, ready_file=None):
    ip = ipaddress.ip_address(address)
    if ip.version != 4 or not ip.is_private or ip.is_loopback or ip.is_link_local:
        raise ValueError('Select an IPv4 address on the trusted local network')
    signature = network_signature(address, allow_public)
    checked = time.monotonic()
    with Relay((address, port), Forward) as relay:
        relay.network = ipaddress.ip_network(network, strict=False) if network else local_subnet(address)
        if ip not in relay.network or not relay.network.is_private:
            raise ValueError('The listener must belong to the selected private subnet')
        relay.directory = directory
        relay.upstream = (upstream, 8443)
        if os.name == 'nt' and not ipaddress.ip_address(upstream).is_loopback:
            relay.upstream_resolver = wsl_upstream_address
        threading.Thread(target=relay.serve_forever, daemon=True).start()
        failures = 0
        try:
            with listener_readiness(ready_file, address):
                while True:
                    # Stop only when sharing was really turned off. A state
                    # read that fails (WSL share briefly unavailable) already
                    # blocks traffic; exiting would leave LAN dead afterwards.
                    if not relay.allowed_hosts() and relay.hosts_confirmed:
                        break
                    if time.monotonic() - checked >= 10:
                        try:
                            current_signature = network_signature(address, allow_public)
                            failures = 0
                            if current_signature != signature:
                                print('LAN stopped: network identity changed', file=sys.stderr, flush=True)
                                revoke_all(directory)
                                break
                        except UntrustedNetwork:
                            print('LAN stopped: network is no longer trusted', file=sys.stderr, flush=True)
                            revoke_all(directory)
                            break
                        except (OSError, ValueError, subprocess.SubprocessError) as error:
                            failures += 1
                            print(f'LAN network check failed ({failures}/{NETWORK_CHECK_FAILURES}): '
                                  + type(error).__name__, file=sys.stderr, flush=True)
                            if failures >= NETWORK_CHECK_FAILURES:
                                print('LAN stopped: network verification failed', file=sys.stderr, flush=True)
                                revoke_all(directory)
                                break
                        checked = time.monotonic()
                    time.sleep(0.5)
        finally:
            relay.shutdown()



@contextmanager
def monitor_update_lock(directory):
    # Separate monitors share a native-host lock; a crash releases it automatically.
    parent = Path(os.environ['LOCALAPPDATA']) / 'ProjectDevelopment' if os.name == 'nt' else Path(directory)
    parent.mkdir(parents=True, exist_ok=True)
    with (parent / '.lan-control.lock').open('a+b') as handle:
        if handle.tell() == 0:
            handle.write(b'0')
            handle.flush()
        handle.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise ValueError('Another monitor is updating LAN access. Wait for it to finish.') from error
        try:
            yield
        finally:
            handle.seek(0)
            if os.name == 'nt':
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def monitor_projects(root):
    """Only checkouts in this workspace can be controlled; never accept shell paths."""
    from config.project_config import resource_namespace
    projects = {}
    for candidate in Path(root).resolve().parent.iterdir():
        if not (candidate / 'dev.sh').is_file() or not (candidate / 'backend/project.py').is_file():
            continue
        namespace = resource_namespace(candidate)
        if namespace in projects:
            raise ValueError('Two checkouts share a resource namespace; resolve the collision first')
        projects[namespace] = candidate
    return projects


def lan_preferences(directory):
    path = Path(directory) / '.lan-preferences.json'
    if not path.exists():
        return {'default': True, 'projects': {}}
    value = json.loads(path.read_text(encoding='utf-8'))
    if (not isinstance(value, dict) or not isinstance(value.get('default'), bool) or not isinstance(value.get('projects'), dict)
            or any(not isinstance(item, bool) for item in value['projects'].values())):
        raise ValueError('Invalid LAN preferences; sharing was not changed')
    return value


def running_projects():
    command = ['podman', 'ps', '--format', '{{index .Labels "com.docker.compose.project"}}']
    options = {}
    if os.name == 'nt':
        command = ['wsl.exe', '-d', 'Ubuntu', '--cd', '/', '--', *command]
        options['creationflags'] = subprocess.CREATE_NO_WINDOW
    return set(subprocess.check_output(command, text=True, timeout=15, **options).split())


def background_lan_ready():
    if os.name == 'nt' or os.geteuid() == 0:
        return True
    result = subprocess.run(['sudo', '-n', '-v'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    return result.returncode == 0


def monitor_defaults(root, directory, attempted):
    """Try new running projects once per monitor; never undo a deliberate off."""
    if not background_lan_ready():
        return
    projects = monitor_projects(root)
    for namespace in sorted(running_projects() & (projects.keys() - attempted)):
        try:
            with monitor_update_lock(directory):
                preferences = lan_preferences(directory)
                if preferences['projects'].get(namespace, preferences['default']):
                    attempted.add(namespace)
                    monitor_change(root, directory, 'on', namespace, remember=False)
        except (OSError, ValueError, subprocess.SubprocessError):
            # Public networks, denied elevation and network changes stay closed.
            # A button can retry; background polling must never repeat prompts.
            attempted.add(namespace)


NATIVE_WINDOWS = os.name == 'nt'


def trusted_network_key():
    """Identity of the connected Windows networks, used to re-apply LAN
    preferences once after the computer joins (or rejoins) a network."""
    if not NATIVE_WINDOWS:
        return None
    command = ("Get-NetConnectionProfile | Where-Object {$_.IPv4Connectivity -ne 'Disconnected'} | "
               "ForEach-Object { $_.Name + '|' + [string]$_.NetworkCategory + '|' + "
               "((Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | "
               "Select-Object -ExpandProperty IPAddress) -join ',') } | Sort-Object")
    return subprocess.check_output(['powershell.exe', '-NoProfile', '-Command', command], text=True, timeout=20,
                                   stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW).strip()


def lan_https_check(address, host, timeout=6):
    """The phone's path, tested from this computer: LAN address -> relay ->
    Traefik -> publicly trusted certificate -> app. Returns the HTTP status line."""
    import ssl
    context = ssl.create_default_context()
    with socket.create_connection((address, 443), timeout=timeout) as raw:
        with context.wrap_socket(raw, server_hostname=host) as tls:
            tls.settimeout(timeout)
            tls.sendall(f'HEAD / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode('ascii'))
            line = tls.recv(256).split(b'\r\n', 1)[0].decode('ascii', 'replace')
    if not line.startswith('HTTP/'):
        raise ValueError('No HTTP response through the LAN relay')
    return line


def public_dns_address(host):
    """The A record phones see (computer hosts files point the same name at loopback)."""
    import urllib.request
    request = urllib.request.Request(f'https://cloudflare-dns.com/dns-query?name={host}&type=A',
                                     headers={'accept': 'application/dns-json'})
    with urllib.request.urlopen(request, timeout=8) as response:
        answers = json.loads(response.read().decode('utf-8')).get('Answer') or []
    return sorted({item['data'] for item in answers if item.get('type') == 1})


def doctor(root, directory):
    """Explain exactly where phone access breaks. Exit 0 only when every check passes."""
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from config.project_config import development_hostname
    problems = 0

    def report(ok, label, detail=''):
        nonlocal problems
        problems += 0 if ok else 1
        print(f'  [{"OK" if ok else "!!"}] {label}' + (f' - {detail}' if detail else ''))

    host = development_hostname(root)
    print(f'LAN check for https://{host}')
    try:
        hosts = enabled_hosts(directory)
        report(host in hosts, 'LAN sharing is on for this project',
               '' if host in hosts else 'run .\\dev.ps1 lan on (or press its LAN button)')
    except OSError as error:
        report(False, 'Sharing state is readable', f'{directory}: {error}')
    state_root = Path(os.environ.get('LOCALAPPDATA', '')) / 'ProjectDevelopment'
    address = upstream = None
    try:
        address = json.loads((state_root / 'lan-ready.json').read_text(encoding='utf-8'))['address']
        listener = json.loads((state_root / 'lan-listener.json').read_text(encoding='utf-8'))
        upstream = listener.get('upstream')
    except (OSError, ValueError, KeyError):
        pass
    report(bool(address), 'LAN relay is running', address or 'not running: run .\\dev.ps1 lan on')
    if address:
        try:
            dns = public_dns_address(host)
            report(dns == [address], 'Public DNS points phones at this computer',
                   f'{host} -> {", ".join(dns) or "no record"} (this computer: {address})')
        except (OSError, ValueError) as error:
            report(False, 'Public DNS lookup', type(error).__name__)
    if NATIVE_WINDOWS and upstream:
        try:
            current = wsl_upstream_address()
            report(current == upstream, 'Relay forwards to the current WSL address',
                   f'relay {upstream}, WSL now {current} (the relay follows it automatically)')
        except (OSError, subprocess.SubprocessError) as error:
            report(False, 'WSL is reachable', type(error).__name__)
    if address:
        try:
            report(True, 'HTTPS works through the LAN address', lan_https_check(address, host))
        except Exception as error:  # report every failure mode, never crash the doctor
            report(False, 'HTTPS works through the LAN address', f'{type(error).__name__}: {error}')
    print()
    if problems:
        print(f'{problems} problem(s) found above.')
    else:
        print('Everything on this computer works. If the phone still cannot open it:')
    print('  - The phone must be on the same Wi-Fi as this computer, not a guest network')
    print('    (guest/isolated networks block devices from reaching each other).')
    print('  - Some routers block public names that point to home addresses ("DNS rebinding')
    print('    protection"). If the phone shows a DNS/"site can\'t be reached" error, add')
    print(f'    {host.split(".", 1)[1]} to the router\'s rebinding exceptions, or set the phone\'s')
    print('    Private DNS to 1dot1dot1dot1.cloudflare-dns.com so it skips the router filter.')
    print('  - Give this computer a fixed address (DHCP reservation) in the router so the')
    print('    phone address never goes stale.')
    return 1 if problems else 0


def windows_relay_healthy():
    """True only while the native Windows relay accepts HTTPS on its LAN address.

    A project's state file alone only says sharing was requested. The relay can
    exit (sleep, crash, IP change), so the monitor must probe the real socket.
    """
    path = Path(os.environ.get('LOCALAPPDATA', '')) / 'ProjectDevelopment' / 'lan-ready.json'
    try:
        address = str(ipaddress.IPv4Address(json.loads(path.read_text(encoding='utf-8'))['address']))
        with socket.create_connection((address, 443), timeout=2):
            return True
    except (OSError, ValueError, KeyError, TypeError):
        return False


def monitor_relay(root, directory):
    """Restart a dead Windows relay once; if that fails, show LAN as off.

    Revoking a failed project keeps the label truthful and stops repeated
    elevation prompts. Turning it on again is an explicit button press.
    """
    if not NATIVE_WINDOWS:
        return
    states = lambda: {path.name[:-len('-lan.state')] for path in Path(directory).glob('*-lan.state')}
    if not states() or windows_relay_healthy():
        return
    projects = monitor_projects(root)
    with monitor_update_lock(directory):
        enabled = states() & projects.keys()
        if not enabled or windows_relay_healthy():
            return
        for namespace in sorted(enabled):
            try:
                monitor_change(root, directory, 'on', namespace, remember=False)
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
        if not windows_relay_healthy():
            for namespace in sorted(enabled):
                try:
                    configure(projects[namespace], 'off', directory)
                except (OSError, ValueError):
                    pass


def monitor_change(root, directory, action, project=None, remember=True):
    if action not in ('on', 'off'):
        raise ValueError('Choose LAN on or off')
    projects = monitor_projects(root)
    if project is not None and project not in projects:
        raise ValueError('Unknown project in this workspace')
    native = os.name == 'nt'
    options = {'creationflags': subprocess.CREATE_NO_WINDOW} if native else {}
    running = running_projects() if action == 'on' else set()
    enabled = {path.name[:-len('-lan.state')] for path in Path(directory).glob('*-lan.state')}
    selected = sorted((running if action == 'on' else enabled) & projects.keys())
    if project is not None:
        if action == 'on' and project not in running:
            raise ValueError('Start this project before enabling LAN')
        selected = [project]
    if remember:
        preferences = lan_preferences(directory)
        if project is None:
            preferences = {'default': action == 'on', 'projects': {}}
        else:
            preferences['projects'][project] = action == 'on'
        atomic_json(Path(directory) / '.lan-preferences.json', preferences)
    if not selected:
        if action == 'off':
            return 'LAN is already off for this workspace.'
        raise ValueError('No running projects were found in this workspace')
    public_session = False
    if action == 'on' and native:
        # Startup remains private-only. An explicit toggle grants only this
        # network's bounded project ingress, without reclassifying Windows.
        trusted = subprocess.check_output([
            'powershell.exe', '-NoProfile', '-Command',
            "Get-NetConnectionProfile | Where-Object {$_.IPv4Connectivity -ne 'Disconnected' -and "
            "$_.NetworkCategory -in @('Private','DomainAuthenticated')} | Select-Object -ExpandProperty InterfaceIndex"
        ], text=True, timeout=15, **options).strip()
        if not trusted:
            if not remember:
                raise ValueError('Automatic LAN sharing stays off on Public networks. Use the LAN button to enable a session on this network.')
            public_session = True

    def apply(namespace, desired):
        checkout = projects[namespace]
        if native:
            script = str(checkout / 'dev.ps1').replace("'", "''")
            flag = ' --allow-public' if public_session and desired == 'on' else ''
            source = f"$ProgressPreference='SilentlyContinue'; & '{script}' lan {desired}{flag}; exit $LASTEXITCODE"
            encoded = base64.b64encode(source.encode('utf-16-le')).decode('ascii')
            command = ['powershell.exe', '-NoProfile', '-OutputFormat', 'Text', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded]
        else:
            command = ['bash', str(checkout / 'dev.sh'), 'lan', desired]
        child_options = dict(options)
        if not native:
            child_options['env'] = {**os.environ, 'DEV_LAN_CONTROLLED': '1'}
        # A detached Windows/WSL worker can inherit pipe handles. Waiting for
        # capture_output EOF would then hang after the launcher itself exited.
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            try:
                result = subprocess.run(command, cwd=checkout, stdout=output, stderr=errors,
                                        timeout=180, **child_options)
            except subprocess.TimeoutExpired:
                # This bounds the launcher wait, not detached Windows/WSL
                # descendants. The caller revokes opt-ins before cleanup.
                raise ValueError('LAN update timed out after 180 seconds; newly enabled access is being revoked.') from None
            if result.returncode:
                errors.seek(0)
                output.seek(0)
                detail = (errors.read() or output.read()).decode('utf-8', errors='replace')
                detail = detail or getattr(result, 'stderr', None) or getattr(result, 'stdout', None) or 'LAN update failed'
                detail = readable_powershell_error(detail)
                raise ValueError(detail[-2500:])

    if action == 'off':
        # Close every selected project's existing connection before launcher cleanup.
        for namespace in selected:
            configure(projects[namespace], 'off', directory)
    changed = []
    try:
        for namespace in selected:
            if action == 'on' and namespace not in enabled:
                changed.append(namespace)
            apply(namespace, action)
    except (OSError, ValueError, subprocess.SubprocessError):
        # A partially enabled workspace must not silently remain shared.
        # Revoke every new opt-in before waiting for any launcher cleanup.
        for namespace in changed:
            try:
                configure(projects[namespace], 'off', directory)
            except (OSError, ValueError):
                # Continue revoking the others, then retry through their launchers.
                pass
        for namespace in changed:
            try:
                apply(namespace, 'off')
            except (OSError, ValueError, subprocess.SubprocessError):
                configure(projects[namespace], 'off', directory)
        raise
    names = ', '.join(projects[namespace].name for namespace in selected)
    scope = ' (current network only)' if public_session else ''
    return f'LAN {action}{scope}: {names}. Your project URLs stay the same.'


def readable_powershell_error(text):
    """PowerShell sends errors to a pipe as CLIXML; show the message, not the XML."""
    if '#< CLIXML' not in text:
        return text
    import html
    parts = re.findall(r'<S S="Error">(.*?)</S>', text, flags=re.S)
    message = ''.join(html.unescape(part) for part in parts)
    message = re.sub(r'_x([0-9A-Fa-f]{4})_', lambda match: chr(int(match[1], 16)), message)
    lines = [line.rstrip() for line in message.splitlines() if line.strip()]
    # The first lines carry the thrown message; the rest is the script position.
    return '\n'.join(lines[:3]) or text


def monitor_request(root, directory, token, request):
    """Accept a small authenticated action, never a shell command or checkout path."""
    if not isinstance(request, dict):
        raise ValueError('Invalid LAN request')
    supplied = request.get('token')
    if not isinstance(supplied, str) or not supplied.isascii() or not secrets.compare_digest(supplied, token):
        raise ValueError('The monitor session has expired. Reopen the monitor.')
    action, project = request.get('action'), request.get('project')
    if action not in ('on', 'off'):
        raise ValueError('Invalid LAN action')
    if project is not None and (not isinstance(project, str) or not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,62}', project)):
        raise ValueError('Invalid project')
    with monitor_update_lock(directory):
        return monitor_change(root, directory, action, project)


def monitor_controller(root, directory, state):
    """Private file IPC works through the Windows/WSL bridge and on native Unix."""
    state = Path(state)
    token = secrets.token_urlsafe(32)
    preferences = lan_preferences(directory)
    atomic_json(state, {'token': token, 'projects': sorted(monitor_projects(root)),
                        'platform': sys.platform,
                        'defaults': preferences['default'] or any(preferences['projects'].values())})
    stop = threading.Event()
    def heartbeat():
        while not stop.is_set():
            try:
                atomic_json(state.parent / 'heartbeat.json', {'time': time.time()})
            except OSError:
                pass
            stop.wait(1)
    def defaults():
        attempted = set()
        network = None
        while not stop.is_set():
            try:
                # Wi-Fi reconnects and sleep/resume revoke sharing for safety.
                # Re-apply the remembered preference once on the new network,
                # instead of leaving LAN off until someone notices.
                current = trusted_network_key()
                if network is not None and current != network:
                    attempted.clear()
                network = current
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
            try:
                monitor_defaults(root, directory, attempted)
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
            try:
                monitor_relay(root, directory)
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
            stop.wait(10)
    threading.Thread(target=heartbeat, daemon=True).start()
    threading.Thread(target=defaults, daemon=True).start()
    try:
        while True:
            request_path = state.parent / 'request.json'
            if not request_path.exists():
                time.sleep(0.1)
                continue
            request = {}
            try:
                if request_path.stat().st_size > 4096:
                    raise ValueError('Invalid request size')
                request = json.loads(request_path.read_text(encoding='utf-8'))
                remove_lan_file(request_path)
                if not isinstance(request, dict) or not re.fullmatch(r'[0-9a-f]{32}', request.get('id', '')):
                    raise ValueError('Invalid request identity')
                message = monitor_request(root, directory, token, request)
                result = {'ok': True, 'message': message}
            except (OSError, ValueError, TypeError, subprocess.SubprocessError) as error:
                remove_lan_file(request_path)
                result = {'ok': False, 'message': str(error)}
            result['id'] = request.get('id') if isinstance(request, dict) else None
            atomic_json(state.parent / 'response.json', result)
    finally:
        stop.set()


def monitor_label(root, directory, state, project=None):
    metadata = json.loads(Path(state).read_text(encoding='utf-8'))
    projects = set(metadata['projects'])
    if project and project not in projects:
        return None
    selected = {project} if project else running_projects() & projects
    enabled = {path.name[:-len('-lan.state')] for path in Path(directory).glob('*-lan.state')}
    return {'project': project, 'action': 'off' if selected and selected <= enabled else 'on'}


ANSI = re.compile(r'\x1b\][^\x1b\x07]*(?:\x1b\\|\x07)|\x1b\[[0-?]*[ -/]*[@-~]')
LAN_LABEL = re.compile(r'\[LAN (?:ON|OFF)\]')


def terminal_columns(text):
    return sum(0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1 for char in text)


def frame_controls(text, controls):
    """Calculate hit regions from the rendered frame, including invisible ANSI/links."""
    result, index = [], 0
    for row, line in enumerate(text.splitlines()):
        plain = ANSI.sub('', line)
        for match in LAN_LABEL.finditer(plain):
            if index >= len(controls):
                break
            result.append({**controls[index], 'row': row, 'column': terminal_columns(plain[:match.start()]),
                           'width': terminal_columns(match.group())})
            index += 1
    return result


def terminal_event(buffer):
    """Incremental VT input parser; releases, unknown escapes and pasted text do not toggle."""
    if not buffer:
        return None, buffer
    if buffer.startswith('\x1b[200~'):
        end = buffer.find('\x1b[201~')
        return (None, buffer) if end < 0 else (('ignore',), buffer[end + 6:])
    mouse = re.match(r'\x1b\[<(\d+);(\d+);(\d+)([Mm])', buffer)
    if mouse:
        code, x, y = map(int, mouse.group(1, 2, 3))
        return ('mouse', code, x - 1, y - 1, mouse[4]), buffer[mouse.end():]
    for sequence, key in [('\x1b[A', 'up'), ('\x1b[B', 'down'), ('\x1bOA', 'up'), ('\x1bOB', 'down'), ('\x1b[Z', 'backtab'),
                          ('\x1b[5~', 'pageup'), ('\x1b[6~', 'pagedown')]:
        if buffer.startswith(sequence):
            return ('key', key), buffer[len(sequence):]
    if buffer.startswith('\x1b'):
        complete = re.match(r'\x1b\[[0-?]*[ -/]*[@-~]', buffer)
        if complete:
            return ('ignore',), buffer[complete.end():]
        if len(buffer) < 64 and (buffer.startswith('\x1b[') or buffer == '\x1b'):
            return None, buffer
        return ('ignore',), buffer[2:]
    return ('key', buffer[0]), buffer[1:]


def monitor_terminal(frame, state):
    # Windows enters through WSL, so all three launchers use the same POSIX TTY.
    import termios
    import tty
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise ValueError('Open the monitor in an interactive terminal')
    try:
        metadata = json.loads(Path(state).read_text(encoding='utf-8')) if state else None
    except (OSError, ValueError):
        metadata = None
    saved = termios.tcgetattr(sys.stdin.fileno())
    old_signals = {kind: signal.getsignal(kind) for kind in (signal.SIGTERM, signal.SIGHUP)}
    def interrupted(*_):
        raise KeyboardInterrupt
    for kind in old_signals:
        signal.signal(kind, interrupted)
    enable = '\x1b[?25l\x1b[?1000h\x1b[?1006h\x1b[?2004h'
    disable = '\x1b[?1000l\x1b[?1006l\x1b[?2004l\x1b[?25h'
    message = '' if metadata else 'LAN controls are unavailable. Start this monitor through the platform launcher.'
    pending, buffer, selected, offset = None, '', 0, 0
    text, controls, signature, last_paint = '', [], None, None

    def authorize():
        if not metadata or metadata.get('platform') == 'win32' or os.geteuid() == 0:
            return True
        if subprocess.run(['sudo', '-n', '-v'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            return True
        sys.stdout.write(disable + '\nLAN needs administrator access to listen on HTTPS.\n')
        sys.stdout.flush()
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, saved)
        try:
            return subprocess.run(['sudo', '-v']).returncode == 0
        finally:
            tty.setcbreak(sys.stdin.fileno())
            sys.stdout.write(enable)
            sys.stdout.flush()

    try:
        tty.setcbreak(sys.stdin.fileno())
        sys.stdout.write(enable)
        if metadata and metadata.get('defaults'):
            authorize()
        while True:
            try:
                path = Path(frame)
                current = path.stat().st_mtime_ns
                if current != signature:
                    data = json.loads(path.read_text(encoding='utf-8'))
                    text = data['text']
                    controls = frame_controls(text, data['controls'])
                    selected = min(selected, max(0, len(controls) - 1))
                    signature = current
            except (OSError, ValueError, KeyError):
                pass
            if pending and metadata:
                try:
                    response = json.loads((Path(state).parent / 'response.json').read_text(encoding='utf-8'))
                    if response.get('id') == pending:
                        message = response.get('message', '')
                        pending = None
                except (OSError, ValueError):
                    pass
                try:
                    alive = json.loads((Path(state).parent / 'heartbeat.json').read_text(encoding='utf-8'))
                    if time.time() - alive['time'] > 15:
                        message = 'LAN controller is unavailable. Reopen the monitor to reconnect.'
                except (OSError, ValueError, KeyError):
                    pass
            try:
                size = os.get_terminal_size(sys.stdout.fileno())
            except OSError:
                size = shutil.get_terminal_size((100, 30))
            clean_message = ' '.join(re.sub(r'[\x00-\x1f\x7f]', '', ANSI.sub('', message)).split())
            message_lines = textwrap.wrap(clean_message, width=max(1, size.columns - 1)) or ['']
            message_lines = message_lines[:max(1, min(3, size.lines - 4))]
            height = max(1, size.lines - len(message_lines) - 2)
            lines = text.splitlines() or ['Loading services...']
            offset = max(0, min(offset, len(lines) - height))
            paint = signature, selected, offset, message, pending, size
            if paint != last_paint:
                output = []
                for row in range(offset, min(len(lines), offset + height)):
                    line = lines[row]
                    # Truncate overlong rows rather than wrap and invalidate mouse coordinates.
                    visible = ANSI.sub('', line)
                    if terminal_columns(visible) > size.columns:
                        column, shortened = 0, ''
                        for char in visible:
                            column += terminal_columns(char)
                            if column > size.columns - 1:
                                break
                            shortened += char
                        line = shortened + '...'
                    elif controls and row == controls[selected]['row']:
                        line = LAN_LABEL.sub(lambda match: '\x1b[7m' + match.group() + '\x1b[27m', line, count=1)
                    output.append(line + '\x1b[0m')
                output.extend([''] * (height - len(output)))
                help_text = 'Tab/arrows select | Space/Enter toggle | Ctrl+C exit | Shift to select text'
                output.append('\x1b[2m' + help_text[:max(1, size.columns - 1)] + '\x1b[0m')
                output.extend(message_lines)
                sys.stdout.write('\x1b[H\x1b[2J' + '\n'.join(output))
                sys.stdout.flush()
                last_paint = paint
            if select.select([sys.stdin], [], [], 0.1)[0]:
                chunk = os.read(sys.stdin.fileno(), 4096)
                if not chunk:
                    break
                buffer += chunk.decode('utf-8', errors='ignore')
            while buffer:
                event, rest = terminal_event(buffer)
                if event is None:
                    break
                buffer = rest
                target = None
                if event[0] == 'mouse':
                    _, code, x, y, phase = event
                    if code in (64, 65):
                        offset += -3 if code == 64 else 3
                    elif code == 0 and phase == 'M' and y < height:
                        target = next((i for i, button in enumerate(controls)
                                       if button['row'] == y + offset and button['column'] <= x < min(size.columns, button['column'] + button['width'])), None)
                elif event[0] == 'key':
                    key = event[1]
                    if key in ('\t', 'down', 'up', 'backtab') and controls:
                        selected = (selected + (-1 if key in ('up', 'backtab') else 1)) % len(controls)
                        offset = min(offset, controls[selected]['row'])
                        offset = max(offset, controls[selected]['row'] - height + 1)
                    elif key in (' ', '\r', '\n') and controls:
                        target = selected
                    elif key in ('pageup', 'pagedown'):
                        offset += -height if key == 'pageup' else height
                if target is not None and not pending and metadata:
                    selected = target
                    offset = min(offset, controls[target]['row'])
                    offset = max(offset, controls[target]['row'] - height + 1)
                    button = controls[target]
                    if button['action'] == 'on' and not authorize():
                        message = 'LAN was not enabled: administrator access was declined.'
                        continue
                    pending = secrets.token_hex(16)
                    atomic_json(Path(state).parent / 'request.json', {'id': pending, 'token': metadata['token'],
                                'action': button['action'], 'project': button['project']})
                    message = 'Updating LAN access...'
    except KeyboardInterrupt:
        pass
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, saved)
        for kind, previous in old_signals.items():
            signal.signal(kind, previous)
        sys.stdout.write('\x1b[0m' + disable + '\n')
        sys.stdout.flush()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['on', 'off', 'status', 'doctor', 'serve', 'monitor', 'monitor-label', 'monitor-frame', 'monitor-terminal'])
    parser.add_argument('--root', default='.')
    parser.add_argument('--directory', default='/tmp/traefik-dynamic')
    parser.add_argument('--address')
    parser.add_argument('--upstream', default='127.0.0.1')
    parser.add_argument('--network')
    parser.add_argument('--allow-public', action='store_true')
    parser.add_argument('--ready-file', help='Private process readiness marker written after all sockets bind')
    parser.add_argument('--relay-source', action='append', default=[])
    parser.add_argument('--discover', action='store_true')
    parser.add_argument('--control-state')
    parser.add_argument('--project')
    parser.add_argument('--frame')
    parser.add_argument('--controls')
    parser.add_argument('--output')
    args = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    if args.action == 'monitor':
        monitor_controller(args.root, args.directory, args.control_state)
    elif args.action == 'monitor-label':
        control = monitor_label(args.root, args.directory, args.control_state, args.project)
        if control:
            print(f'{control["project"] or "*"}|{control["action"]}')
    elif args.action == 'monitor-frame':
        controls = []
        for line in Path(args.controls).read_text(encoding='utf-8').splitlines():
            if line.startswith('@lan|'):
                _, project, action = line.split('|')
                controls.append({'project': None if project == '*' else project, 'action': action})
        atomic_json(args.output, {'text': Path(args.frame).read_text(encoding='utf-8'), 'controls': controls})
    elif args.action == 'monitor-terminal':
        monitor_terminal(args.frame, args.control_state)
    elif args.action == 'doctor':
        sys.exit(doctor(args.root, args.directory))
    elif args.action == 'serve':
        serve(args.directory, args.address, args.upstream, network=args.network, allow_public=args.allow_public, ready_file=args.ready_file)
    else:
        relays = ['127.0.0.1/32', '::1/128'] + args.relay_source
        for source in relays:
            ipaddress.ip_network(source)
        # Running the source file directly keeps dependency-free host commands usable.
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
        result = configure(args.root, args.action, args.directory, relays, args.discover)
        print(f'{result["url"]} - LAN {"on" if result["enabled"] else "off"}')
