"""Opt-in LAN ingress and mDNS discovery; no app ports or data stores exposed.

The LAN entrypoint has routes only for enabled projects. Local-only routes use
separate loopback listeners. Only the public CA certificate is exported for phones.
"""
import argparse
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
        state.unlink(missing_ok=True)
        route.unlink(missing_ok=True)
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
        state.unlink(missing_ok=True)
        state.with_suffix('.yml').unlink(missing_ok=True)


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
        relay.network = ipaddress.ip_network(network or (address + '/24'), strict=False)
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


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['on', 'off', 'status', 'serve'])
    parser.add_argument('--root', default='.')
    parser.add_argument('--directory', default='/tmp/traefik-dynamic')
    parser.add_argument('--address')
    parser.add_argument('--upstream', default='127.0.0.1')
    parser.add_argument('--network')
    parser.add_argument('--relay-source', action='append', default=[])
    parser.add_argument('--discover', action='store_true')
    args = parser.parse_args()
    if args.action == 'serve':
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
