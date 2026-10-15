"""Controlled LAN ingress and mDNS discovery; no app ports or data stores exposed.

The LAN entrypoint has routes only for enabled projects. Local-only routes use
separate loopback listeners. Only the public CA certificate is exported for phones.
"""
import argparse
import base64
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import secrets
import ipaddress
import json
import os
from pathlib import Path
import re
import select
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time


def identity(root):
    name = re.sub(r'[^a-z0-9.-]', '', Path(root).name.lower())
    if not name or '..' in name or name.startswith(('.', '-')) or name.endswith(('.', '-')):
        raise ValueError('The project folder must be a DNS-compatible name')
    return name, re.sub(r'[^a-z0-9]', '', name)


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
                 'priority': 10 if kind == 'frontend' else 100, 'tls': {}}
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
            route = {'entryPoints': ['lan'], 'rule': rule,
                     'service': service if '@' in service else service + '@docker',
                     'priority': int(labels.get(prefix + 'priority', '10')), 'tls': {},
                     'middlewares': [f'{project}-lan-relay']}
            for item in labels.get(prefix + 'middlewares', '').split(','):
                if item:
                    route['middlewares'].append(item if '@' in item else item + '@docker')
            routes[router + '-lan'] = route
    if not routes:
        raise ValueError('Restart the project with its .local hostname before enabling LAN')
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
    name, project = identity(root)
    from config.project_config import resource_namespace
    project = resource_namespace(root)
    host = name + '.local'
    directory = Path(directory)
    route = directory / f'{project}-lan.yml'
    state = directory / f'{project}-lan.state'
    if action == 'on':
        config = lan_routes(project, host, relays)
        if discover:
            config['http']['routers'] = discovered_routes(project, host)
        atomic_json(route, config)
        atomic_json(state, {'host': host, 'checkout': str(Path(root).resolve())})
    elif action == 'off':
        # Revoke the relay first, including established WebSocket connections.
        remove_lan_file(state)
        remove_lan_file(route)
    return {'host': host, 'enabled': state.exists(), 'url': f'https://{host}'}


def enabled_hosts(directory):
    result = set()
    for path in Path(directory).glob('*-lan.state'):
        try:
            host = json.loads(path.read_text(encoding='utf-8'))['host']
            if re.fullmatch(r'[a-z0-9][a-z0-9.-]*\.local', host):
                result.add(host)
        except (OSError, ValueError, KeyError):
            continue
    return result


def network_signature(address):
    """Windows Wi-Fi/profile changes revoke the current sharing session."""
    if os.name != 'nt':
        return None
    # address has already been validated as an IPv4 literal, never shell input.
    command = (f"$a=Get-NetIPAddress -IPAddress '{address}' -AddressFamily IPv4 -ErrorAction Stop; "
               "$p=Get-NetConnectionProfile -InterfaceIndex $a.InterfaceIndex -ErrorAction Stop; "
               "if($p.NetworkCategory -eq 'Public'){throw 'Untrusted network'}; "
               "$g=Get-NetRoute -InterfaceIndex $a.InterfaceIndex -DestinationPrefix '0.0.0.0/0' "
               "-ErrorAction Stop | Select-Object -First 1 -ExpandProperty NextHop; "
               "@{name=$p.Name;index=$a.InterfaceIndex;category=[string]$p.NetworkCategory;gateway=$g} | ConvertTo-Json -Compress")
    value = subprocess.check_output(['powershell.exe', '-NoProfile', '-Command', command],
                                    timeout=8, stderr=subprocess.DEVNULL,
                                    creationflags=subprocess.CREATE_NO_WINDOW, text=True)
    return json.dumps(json.loads(value), sort_keys=True)


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


def dns_name(packet, offset):
    labels, visited = [], set()
    end = None
    while True:
        if offset in visited or offset >= len(packet):
            raise ValueError('Invalid DNS name')
        visited.add(offset)
        size = packet[offset]
        if size & 192 == 192:
            if offset + 1 >= len(packet):
                raise ValueError('Truncated DNS pointer')
            if end is None:
                end = offset + 2
            offset = ((size & 63) << 8) | packet[offset + 1]
            continue
        offset += 1
        if size == 0:
            return '.'.join(labels).lower(), end or offset
        if size > 63 or offset + size > len(packet):
            raise ValueError('Invalid DNS label')
        labels.append(packet[offset:offset + size].decode('ascii'))
        offset += size


def mdns_answer(packet, hosts, address):
    if len(packet) < 12 or packet[2] & 128:
        return None
    count = int.from_bytes(packet[4:6], 'big')
    if count > 64:
        return None
    p, answers = 12, []
    try:
        for _ in range(count):
            name, p = dns_name(packet, p)
            kind, klass = struct.unpack('!HH', packet[p:p + 4])
            p += 4
            if name in hosts and kind in (1, 255) and klass & 32767 in (1, 255):
                encoded = b''.join(bytes([len(label)]) + label.encode() for label in name.split('.')) + b'\0'
                answers.append(encoded + struct.pack('!HHIH', 1, 32769, 30, 4) + socket.inet_aton(address))
    except (ValueError, IndexError, UnicodeError, struct.error):
        return None
    if not answers:
        return None
    return struct.pack('!HHHHHH', 0, 0x8400, 0, len(answers), 0, 0) + b''.join(answers)


class Relay(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


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
            if host not in enabled_hosts(server.directory):
                return
            with socket.create_connection(server.upstream, timeout=5) as target:
                target.sendall(data)
                self.request.settimeout(2)
                target.settimeout(2)
                peers = [self.request, target]
                while host in enabled_hosts(server.directory):
                    readable, _, _ = select.select(peers, [], [], 1)
                    for source in readable:
                        block = source.recv(65536)
                        if not block:
                            return
                        (target if source is self.request else self.request).sendall(block)
        except (OSError, ValueError):
            return


def serve(directory, address, upstream, port=443, network=None):
    ip = ipaddress.ip_address(address)
    if ip.version != 4 or not ip.is_private or ip.is_loopback or ip.is_link_local:
        raise ValueError('Select an IPv4 address on the trusted local network')
    signature = network_signature(address)
    checked = time.monotonic()
    with Relay((address, port), Forward) as relay:
        relay.network = ipaddress.ip_network(network, strict=False) if network else local_subnet(address)
        if ip not in relay.network or not relay.network.is_private:
            raise ValueError('The listener must belong to the selected private subnet')
        relay.directory = directory
        relay.upstream = (upstream, 8443)
        threading.Thread(target=relay.serve_forever, daemon=True).start()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP) as mdns:
            mdns.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            mdns.bind(('', 5353))
            mdns.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                            socket.inet_aton('224.0.0.251') + socket.inet_aton(address))
            mdns.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(address))
            mdns.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
            mdns.settimeout(1)
            while enabled_hosts(directory):
                if time.monotonic() - checked >= 10:
                    try:
                        if network_signature(address) != signature:
                            revoke_all(directory)
                            break
                    except (OSError, ValueError, subprocess.SubprocessError):
                        revoke_all(directory)
                        break
                    checked = time.monotonic()
                try:
                    packet, sender = mdns.recvfrom(9000)
                    answer = mdns_answer(packet, enabled_hosts(directory), address)
                    if answer:
                        mdns.sendto(answer, ('224.0.0.251', 5353) if sender[1] == 5353 else sender)
                except socket.timeout:
                    pass
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


def monitor_defaults(root, directory, attempted):
    """Try new running projects once per monitor; never undo a deliberate off."""
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
    if action == 'on' and native:
        # Refuse before preparing any routes or displaying elevation prompts.
        trusted = subprocess.check_output([
            'powershell.exe', '-NoProfile', '-Command',
            "Get-NetConnectionProfile | Where-Object {$_.IPv4Connectivity -ne 'Disconnected' -and "
            "$_.NetworkCategory -in @('Private','DomainAuthenticated')} | Select-Object -ExpandProperty InterfaceIndex"
        ], text=True, timeout=15, **options).strip()
        if not trusted:
            raise ValueError('LAN remains off. Windows marks this network as Public. Only enable sharing on a trusted Private or Domain network.')

    def apply(namespace, desired):
        checkout = projects[namespace]
        if native:
            script = str(checkout / 'dev.ps1').replace("'", "''")
            source = f"& '{script}' lan {desired}; exit $LASTEXITCODE"
            encoded = base64.b64encode(source.encode('utf-16-le')).decode('ascii')
            command = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded]
        else:
            command = ['bash', str(checkout / 'dev.sh'), 'lan', desired]
        result = subprocess.run(command, cwd=checkout, capture_output=True, text=True,
                                encoding='utf-8', errors='replace', **options)
        if result.returncode:
            raise ValueError((result.stderr or result.stdout or 'LAN update failed')[-2500:])

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
        for namespace in changed:
            try:
                apply(namespace, 'off')
            except (OSError, ValueError, subprocess.SubprocessError):
                configure(projects[namespace], 'off', directory)
        raise
    names = ', '.join(projects[namespace].name for namespace in selected)
    return f'LAN {action}: {names}. Your project URLs stay the same.'


def monitor_server(root, directory):
    """A monitor-only loopback control, authenticated independently of app sessions."""
    token = secrets.token_urlsafe(32)
    nonce = secrets.token_urlsafe(24)
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # Never log control tokens or app output.

        def valid_host(self):
            return self.headers.get('Host') == f'127.0.0.1:{self.server.server_port}'

        def respond(self, status, body, kind='application/json'):
            data = body.encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', kind + '; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy',
                             "default-src 'none'; script-src 'nonce-" + nonce + "'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if not self.valid_host():
                self.respond(403, '{}')
                return
            if self.path != '/':
                self.respond(404, '{}')
                return
            # GET/prefetch never changes state. Only a real document executes the
            # authenticated same-origin POST; the secret stays in the URL fragment.
            self.respond(200, """<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Local network</title>
<style>:root{color-scheme:dark}body{font:17px/1.6 system-ui;max-width:640px;margin:12vh auto;padding:24px;background:#15151b;color:#eee}h1{font-size:28px}p{white-space:pre-wrap;color:#bbb}</style>
<h1>Local network</h1><p id="result">Updating LAN access…</p>
<script nonce=""" + '"' + nonce + '"' + """>
const parameters = new URLSearchParams(location.hash.slice(1));
history.replaceState(null, '', '/');
(async () => {
  try {
    const response = await fetch('/toggle', {method:'POST', headers:{'Content-Type':'application/json',
      'Authorization':'Bearer ' + parameters.get('token')}, body:JSON.stringify({action:parameters.get('action'), project:parameters.get('project')})});
    const result = await response.json();
    document.getElementById('result').textContent = result.message || 'Use the LAN control in your terminal to try again.';
  } catch (_) {document.getElementById('result').textContent = 'The monitor has closed. Reopen it and try again.';}
})();
</script></html>""", 'text/html')

        def do_POST(self):
            origin = f'http://127.0.0.1:{self.server.server_port}'
            if (not self.valid_host() or self.headers.get('Origin') != origin
                    or not secrets.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + token)):
                self.respond(403, json.dumps({'message': 'Use the LAN control in your terminal.'}))
                return
            if self.path != '/toggle' or self.headers.get('Content-Type') != 'application/json':
                self.respond(400, '{}')
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 256:
                    raise ValueError('Invalid request size')
                self.connection.settimeout(5)
                request = json.loads(self.rfile.read(length))
                action = request.get('action')
                project = request.get('project')
                if project is not None and (not isinstance(project, str) or not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,62}', project)):
                    raise ValueError('Invalid project')
                if action not in ('on', 'off'):
                    raise ValueError('Invalid LAN action')
            except (ValueError, OSError, AttributeError):
                self.respond(400, '{}')
                return
            if not lock.acquire(blocking=False):
                self.respond(409, json.dumps({'message': 'A LAN update is already running. Wait for it to finish.'}))
                return
            try:
                with monitor_update_lock(directory):
                    message = monitor_change(root, directory, action, project)
                self.respond(200, json.dumps({'message': message}))
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                self.respond(400, json.dumps({'message': str(error)}))
            finally:
                lock.release()

    return ThreadingHTTPServer(('127.0.0.1', 0), Handler), token


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['on', 'off', 'status', 'serve', 'monitor', 'monitor-link'])
    parser.add_argument('--root', default='.')
    parser.add_argument('--directory', default='/tmp/traefik-dynamic')
    parser.add_argument('--address')
    parser.add_argument('--upstream', default='127.0.0.1')
    parser.add_argument('--network')
    parser.add_argument('--relay-source', action='append', default=[])
    parser.add_argument('--discover', action='store_true')
    parser.add_argument('--control-state')
    parser.add_argument('--project')
    args = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    if args.action == 'monitor':
        server, token = monitor_server(args.root, args.directory)
        with server:
            atomic_json(args.control_state, {'url': f'http://127.0.0.1:{server.server_port}', 'token': token,
                                             'projects': sorted(monitor_projects(args.root))})
            stop = threading.Event()
            def defaults():
                attempted = set()
                while not stop.is_set():
                    try:
                        monitor_defaults(args.root, args.directory, attempted)
                    except (OSError, ValueError, subprocess.SubprocessError):
                        pass
                    stop.wait(10)
            threading.Thread(target=defaults, daemon=True).start()
            try:
                server.serve_forever()
            finally:
                stop.set()
    elif args.action == 'monitor-link':
        state = json.loads(Path(args.control_state).read_text(encoding='utf-8'))
        enabled = {path.name[:-len('-lan.state')] for path in Path(args.directory).glob('*-lan.state')}
        projects = set(state['projects']) if 'projects' in state else monitor_projects(args.root).keys()
        if args.project and args.project not in projects:
            sys.exit(0)
        selected = {args.project} if args.project else running_projects() & projects
        action = 'off' if selected and selected <= enabled else 'on'
        scope = f'&project={args.project}' if args.project else ''
        print(f'{state["url"]}/#token={state["token"]}{scope}&action={action}')
    elif args.action == 'serve':
        serve(args.directory, args.address, args.upstream, network=args.network)
    else:
        relays = ['127.0.0.1/32', '::1/128'] + args.relay_source
        for source in relays:
            ipaddress.ip_network(source)
        # Running the source file directly keeps dependency-free host commands usable.
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
        result = configure(args.root, args.action, args.directory, relays, args.discover)
        print(f'{result["url"]} - LAN {"on" if result["enabled"] else "off"}')
