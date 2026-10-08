"""Dependency-free discovery and literal project options for shared dev tools.

Reading literals avoids executing integrations in project.py during bootstrap.
Run: python config/project_config.py <project-root> <option>
"""
import ast
import argparse
import fnmatch
import json
import os
import re
import secrets
import runpy
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath
from urllib.request import Request, urlopen
from urllib.parse import urlsplit

MOBILE_SKIP = {'shared', 'node_modules', 'scripts', 'packages', 'builds'}

# Shared architecture boundaries. New files inside shared directories are
# discovered automatically; application source and project.py stay project-owned.
SHARED_PATHS = (
    'AGENTS.md', 'dev.sh', 'dev.ps1', 'dev.yml', '.gitattributes', '.dockerignore', '.vercelignore',
    'backend/config/*', 'backend/manage.py', 'backend/backup/*.sh',
    'backend/requirements/base.txt', 'backend/requirements/development.txt',
    'backend/requirements/deployment.txt',
    'frontend/web/Dockerfile', 'frontend/web/.dockerignore',
    'frontend/web/next.config.shared.ts',
    'frontend/web/package.json', 'frontend/web/eslint.config.mjs',
    '.github/dependabot.yml', '.github/workflows/dependency-checks.yml',
    '.github/workflows/template-sync.yml', '.github/workflows/dependency-automerge.yml',
    '.github/workflows/vercel-deploy.yml',
    'frontend/mobile/Dockerfile', 'frontend/mobile/.dockerignore',
    'frontend/mobile/.npmrc', 'frontend/mobile/mobile.sh',
    'frontend/mobile/metro.config.base.js',
)
RETIRED_SHARED_PATHS = (
    'backend/config/.env.example', 'backend/config/Dockerfile.ml-service',
    'backend/config/test_template_config.py',
    '.sh/dev_qr_server.py',
)
PROJECT_MARKER = '# Project-specific integrations'
WEB_CORE_DEPENDENCIES = ('next', 'react', 'react-dom')
WEB_CORE_DEV_DEPENDENCIES = (
    'eslint', 'eslint-config-next', 'typescript', '@types/node',
    '@types/react', '@types/react-dom', 'tailwindcss', '@tailwindcss/postcss',
)


def merge_web_package(template, project):
    """Sync only framework/tool versions; preserve app packages and commands."""
    remote = json.loads(template)
    local = json.loads(project) if project is not None else remote.copy()
    for section, names in [('dependencies', WEB_CORE_DEPENDENCIES),
                           ('devDependencies', WEB_CORE_DEV_DEPENDENCIES)]:
        target = local.setdefault(section, {})
        for name in names:
            if name in remote.get(section, {}):
                incoming = remote[section][name]
                current = target.get(name, '')
                def version(value):
                    match = re.fullmatch(r'[~^]?(\d+(?:\.\d+){0,2})', value)
                    return tuple(int(part) for part in match.group(1).split('.')) if match else None
                older, newer = version(current), version(incoming)
                if older is None or newer is None or newer >= older:
                    target[name] = incoming
    scripts = local.setdefault('scripts', {})
    for name in ('dev', 'build', 'lint', 'typecheck'):
        if name in remote.get('scripts', {}):
            scripts[name] = remote['scripts'][name]
    if scripts.get('export') == 'next export':
        del scripts['export']
    local.setdefault('engines', {}).update(remote.get('engines', {}))
    return (json.dumps(local, indent=2, ensure_ascii=False) + '\n').encode()


def project_option(root, name, default=None):
    source = Path(root) / 'backend' / 'project.py'
    if not source.is_file():
        return default
    tree = ast.parse(source.read_text(encoding='utf-8-sig'), filename=str(source))
    for node in tree.body:
        if isinstance(node, ast.Assign):
            if any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
                try:
                    return ast.literal_eval(node.value)
                except ValueError as exc:
                    raise ValueError(f'{name} in {source} must be a literal value') from exc
    return default


def find_apps(base_dir, exclude_dirs=None):
    excluded = set(exclude_dirs or ()) | {'config', '__pycache__'}
    return sorted(
        p.name for p in Path(base_dir).iterdir()
        if p.is_dir() and p.name not in excluded and (p / '__init__.py').is_file()
    )


def mobile_apps(root):
    mobile_dir = Path(root) / 'frontend' / 'mobile'
    if not mobile_dir.is_dir():
        return []
    names = sorted((
        p.name for p in mobile_dir.iterdir()
        if p.is_dir() and p.name not in MOBILE_SKIP and (p / 'package.json').is_file()
    ), key=lambda name: (name.casefold(), name))
    order = project_option(root, 'MOBILE_APP_ORDER', [])
    return list(dict.fromkeys([name for name in order if name in names] + names))


def sync_paths(root):
    root = Path(root)
    paths = [f'backend/{name}/' for name in find_apps(root / 'backend')]
    paths += [f'frontend/mobile/{name}/' for name in mobile_apps(root)]
    paths += [config['path'].rstrip('/') + '/'
              for config in project_option(root, 'WATCHOS_APPS', {}).values()]
    paths += project_option(root, 'SYNC_PROJECT_PATHS', [])
    return list(dict.fromkeys(paths))


def environment_keys(root):
    """Discover active inputs in this checkout without importing project code."""
    root = Path(root)
    found = set(project_option(root, 'ENV_DEFAULTS', {}))
    skip = {'.git', '.venv', 'venv', 'node_modules', '.next', '.expo',
            '__pycache__', 'staticfiles', 'migrations', 'build', 'dist', 'media'}
    internal = {'DJANGO_SETTINGS_MODULE', 'PYTHONPATH', 'NODE_ENV', 'CI',
                'HOME', 'PATH', 'USER', 'PORT', 'PYTHONDONTWRITEBYTECODE',
                'PYTHONUNBUFFERED', 'PIP_NO_CACHE_DIR'}
    for directory in (root / 'backend', root / 'frontend'):
        for parent, directories, files in os.walk(directory):
            directories[:] = [name for name in directories if name not in skip]
            for name in files:
                path = Path(parent) / name
                if name.startswith(('test', '.')) or 'tests' in path.parts:
                    continue
                if path.name in {'project_config.py', 'watchos.py'}:
                    continue  # tooling options are optional, not application inputs
                if path.suffix == '.py':
                    tree = ast.parse(path.read_text(encoding='utf-8-sig'), filename=str(path))
                    for node in ast.walk(tree):
                        if isinstance(node, ast.Call) and node.args:
                            function = ast.unparse(node.func)
                            if function in {'os.getenv', 'os.environ.get', 'env_value', 'env_int', 'env_bool'}:
                                key = node.args[0]
                                if isinstance(key, ast.Constant) and isinstance(key.value, str):
                                    found.add(key.value)
                        elif isinstance(node, ast.Subscript) and ast.unparse(node.value) == 'os.environ':
                            if isinstance(node.slice, ast.Constant) and isinstance(node.slice.value, str):
                                found.add(node.slice.value)
                elif path.suffix == '.sh':
                    source = '\n'.join(line for line in path.read_text(encoding='utf-8-sig').splitlines()
                                       if not line.lstrip().startswith('#'))
                    found.update(re.findall(r'\$(?:\{)?([A-Z][A-Z0-9_]*)', source))
                    found.update(re.findall(r'''os\.getenv\(['"]([A-Z][A-Z0-9_]*)['"]''', source))
                elif path.suffix in {'.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs'}:
                    source = path.read_text(encoding='utf-8-sig')
                    # Keep strings intact while discarding JS comments (URLs contain //).
                    tokens = re.compile(r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|//[^\n]*|/\*[\s\S]*?\*/''')
                    source = tokens.sub(lambda match: '' if match.group().startswith(('//', '/*')) else match.group(), source)
                    found.update(re.findall(r'process\.env\.([A-Z][A-Z0-9_]*)', source))
                    found.update(re.findall(r'''process\.env\[['"]([A-Z][A-Z0-9_]*)['"]\]''', source))
    # Project service extensions may have inputs referenced only by Compose.
    services = project_option(root, 'COMPOSE_SERVICES', '')
    services = '\n'.join(line for line in services.splitlines() if not line.lstrip().startswith('#'))
    found.update(re.findall(r'\$\{([A-Z][A-Z0-9_]*)', services))
    return found - internal


def bootstrap_environment(root):
    """Create a minimal local environment; existing values are never copied."""
    root = Path(root)
    target = root / '.env'
    if target.exists():
        return
    defaults = {'DJANGO_SECRET_KEY': secrets.token_urlsafe(48), 'DJANGO_DEBUG': 'True',
                'DOMAIN': 'localhost', 'DB_HOST': 'db', 'DB_PORT': '5432',
                'DB_NAME': 'postgres', 'DB_USER': 'postgres', 'DB_PASSWORD': 'postgres'}
    # Projects explicitly declare optional integrations/defaults here, as literals.
    defaults.update(project_option(root, 'ENV_DEFAULTS', {}))
    if mobile_apps(root):
        defaults.setdefault('EXPO_PUBLIC_API_URL', 'http://localhost:8000')
    keys = environment_keys(root)
    lines = ['# Local environment. Do not commit secrets.',
             '# Optional settings use code defaults; project defaults live in backend/project.py.']
    for key, value in defaults.items():
        if key not in keys:
            continue
        if not re.fullmatch(r'[A-Z][A-Z0-9_]*', key) or '\n' in str(value) or '\r' in str(value):
            raise ValueError('ENV_DEFAULTS must contain dotenv names and single-line values')
        lines.append(f'{key}={value}')
    target.write_text('\n'.join(lines) + '\n', encoding='utf-8')


def environment_values(root, include_environment=False):
    """Read simple dotenv assignments as data, preserving embedded '=' signs."""
    # Host tools read the selected checkout. Inherited project credentials and
    # public build variables must not leak from a previously launched project.
    values = dict(os.environ) if include_environment else {}
    source = Path(root) / '.env'
    if source.is_file():
        for line in source.read_text(encoding='utf-8-sig').splitlines():
            match = re.match(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$', line)
            if not match:
                continue
            name, value = match.groups()
            value = value.strip()
            if len(value) >= 2 and value[0] in ('"', "'") and value[-1] == value[0]:
                value = value[1:-1]
            else:
                value = re.sub(r'\s+#.*$', '', value).rstrip()
            values[name] = value
    return values


def project_environment(root):
    """Keep host tooling paths, replacing application inputs with this .env."""
    keys = environment_keys(root) - {'DEV_SOURCE_DIR'}
    values = {key: value for key, value in os.environ.items()
              if key not in keys and not key.startswith(('EXPO_PUBLIC_', 'NEXT_PUBLIC_'))}
    values.update(environment_values(root))
    return values


def exposure_check_command(root):
    values = environment_values(root)
    url = urlsplit(values.get('CLOUDFLARE_TUNNEL_URL', ''))
    if values.get('CLOUDFLARE_TUNNEL_TOKEN') and (url.scheme != 'https' or not url.hostname or url.username or url.password
            or url.path not in ('', '/') or url.query or url.fragment
            or url.hostname.endswith(('.trycloudflare.com', '.localhost'))
            or url.hostname in ('localhost', '127.0.0.1', '::1')):
        raise ValueError('Set a fixed CLOUDFLARE_TUNNEL_URL=https://your-hostname in the root .env')
    command = project_option(root, 'PUBLIC_EXPOSURE_CHECK_COMMAND', [])
    if not isinstance(command, list) or not command or any(
            not isinstance(argument, str) or not argument or '\n' in argument for argument in command):
        raise ValueError('Declare a literal PUBLIC_EXPOSURE_CHECK_COMMAND list in backend/project.py')
    return command


def mobile_build_environment(root, profile):
    values = environment_values(root)
    public = {key: value for key, value in values.items() if key.startswith('EXPO_PUBLIC_')}
    suffix = f'_{profile.upper()}'
    for key, value in list(public.items()):
        if key.endswith(suffix) and value:
            public[key[:-len(suffix)]] = value
    public['EXPO_PUBLIC_ENV'] = profile
    if profile == 'production' and not values.get('EXPO_PUBLIC_API_URL_PRODUCTION'):
        raise ValueError('Set EXPO_PUBLIC_API_URL_PRODUCTION for production mobile builds; the URL is never guessed from the folder name')
    return public


def android_metadata(root, android_dir):
    """Apply only metadata explicitly configured by this project."""
    metadata = project_option(root, 'MOBILE_ANDROID_METADATA', {})
    manifest = Path(android_dir) / 'app/src/main/AndroidManifest.xml'
    if not metadata or not manifest.is_file():
        return
    values = environment_values(root)
    namespace = 'http://schemas.android.com/apk/res/android'
    ET.register_namespace('android', namespace)
    tree = ET.parse(manifest, parser=ET.XMLParser(target=ET.TreeBuilder(insert_comments=True)))
    application = tree.getroot().find('application')
    if application is None:
        return
    changed = False
    for name, env_key in metadata.items():
        value = values.get(env_key)
        if not value:
            continue
        element = next((item for item in application.findall('meta-data')
                        if item.get(f'{{{namespace}}}name') == name), None)
        if element is None:
            element = ET.SubElement(application, 'meta-data', {f'{{{namespace}}}name': name})
        element.set(f'{{{namespace}}}value', value)
        changed = True
    if changed:
        tree.write(manifest, encoding='utf-8', xml_declaration=True)


def is_shared(path, protected=()):
    parts = PurePosixPath(path).parts
    if not parts or PurePosixPath(path).is_absolute() or '..' in parts:
        return False
    if any(part in {'__pycache__', 'staticfiles', 'node_modules', '.git'} for part in parts):
        return False
    if any(part.startswith('.env') for part in parts) or path in RETIRED_SHARED_PATHS:
        return False
    if any(path.startswith(prefix) if prefix.endswith('/') else path == prefix for prefix in protected):
        return False
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in SHARED_PATHS)


def shared_inventory(root):
    output = subprocess.check_output(
        ['git', '-C', str(root), 'ls-files', '--cached', '--others', '--exclude-standard', '-z']
    ).decode('utf-8')
    return sorted({path for path in output.split('\0') if path and is_shared(path)
                   and (Path(root) / path).is_file()})


def tracked_shared_paths(root, deleted=False):
    command = ['git', '-C', str(root), 'ls-files', '-z']
    if deleted:
        command.append('--deleted')
    return {path for path in subprocess.check_output(command).decode('utf-8').split('\0')
            if path and is_shared(path)}


def merge_requirements(template, project):
    """Update core requirements while retaining this project's integrations."""
    if project is None:
        return template
    remote = template.decode('utf-8-sig').replace('\r\n', '\n')
    local = project.decode('utf-8-sig').replace('\r\n', '\n')
    remote_top = remote.split(PROJECT_MARKER, 1)[0].rstrip()
    # Never roll back a project patch that arrived before the template update.
    pinned = re.compile(r'^([A-Za-z0-9_.-]+)==(\d+(?:\.\d+)*)$')
    local_pins = {}
    for line in local.split(PROJECT_MARKER, 1)[0].splitlines():
        match = pinned.fullmatch(line.strip())
        if match:
            local_pins[match.group(1).lower()] = (tuple(map(int, match.group(2).split('.'))), line)
    lines = []
    for line in remote_top.splitlines():
        match = pinned.fullmatch(line.strip())
        previous = local_pins.get(match.group(1).lower()) if match else None
        if previous and previous[0] > tuple(map(int, match.group(2).split('.'))):
            line = previous[1]
        lines.append(line)
    remote_top = '\n'.join(lines)
    if PROJECT_MARKER in local:
        local_tail = local.split(PROJECT_MARKER, 1)[1]
        return (remote_top + '\n\n' + PROJECT_MARKER + local_tail).rstrip().encode() + b'\n'
    # First migration: keep dependencies absent from the template core.
    def key(line):
        line = line.strip()
        if not line or line.startswith('#'):
            return None
        match = re.match(r'([A-Za-z0-9_.-]+)', line)
        return re.sub(r'[-_.]+', '-', match.group(1)).lower() if match else line
    core = {key(line) for line in remote_top.splitlines()} - {None}
    extras = [line for line in local.splitlines() if key(line) and key(line) not in core]
    return (remote_top + '\n\n' + PROJECT_MARKER + '\n' + '\n'.join(extras)).rstrip().encode() + b'\n'


def check_project_isolation(root, project, hosts):
    """Reject container namespaces or hostnames already owned by another checkout."""
    identifiers = subprocess.check_output(['podman', 'ps', '-aq'], text=True).split()
    if not identifiers:
        return
    containers = json.loads(subprocess.check_output(['podman', 'inspect', *identifiers], text=True))
    root = Path(root).resolve()
    for container in containers:
        labels = container.get('Config', {}).get('Labels') or {}
        owner = labels.get('com.docker.compose.project') or labels.get('io.podman.compose.project')
        directory = labels.get('com.docker.compose.project.working_dir')
        if owner == project:
            if directory and Path(directory).resolve() != root:
                raise ValueError(f'Project namespace {project!r} already belongs to {directory}. Use a distinct project folder name.')
            continue
        for key, rule in labels.items():
            if key.startswith('traefik.http.routers.') and key.endswith('.rule'):
                for expression in re.findall(r'Host\(([^)]*)\)', rule):
                    claimed = re.findall(r'[`"]([^`"]+)[`"]', expression)
                    overlap = set(claimed) & set(hosts)
                    if overlap:
                        raise ValueError(f'Hostname {sorted(overlap)[0]!r} is already routed by {owner or container.get("Name", "another container")}. Use a distinct project folder name.')


def configured_repo(root):
    repo = environment_values(root).get('SYNC_TEMPLATE_REPO') or project_option(root, 'SYNC_TEMPLATE_REPO', '')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ValueError('Set SYNC_TEMPLATE_REPO=owner/repository in project.py or the root .env')
    return repo


def local_template(root, repo, explicit=None):
    if explicit:
        candidate = Path(explicit).expanduser().resolve()
        if not (candidate / '.git').exists():
            raise ValueError(f'Template directory is not a Git checkout: {candidate}')
        return candidate
    for candidate in (Path(root).parent / repo.split('/')[1], Path.home() / repo.split('/')[1]):
        if not (candidate / '.git').exists():
            continue
        try:
            origin = subprocess.check_output(['git', '-C', str(candidate), 'remote', 'get-url', 'origin'], text=True).strip()
        except subprocess.CalledProcessError:
            continue
        if origin.removesuffix('.git').endswith('/' + repo) or origin.removesuffix('.git').endswith(':' + repo):
            return candidate.resolve()
    return None


def remote_template(repo):
    headers = {'User-Agent': 'template-sync', 'Accept': 'application/vnd.github+json'}
    token = os.getenv('GITHUB_TOKEN') or os.getenv('GH_TOKEN')
    if token:
        headers['Authorization'] = f'Bearer {token}'
    def read(url):
        with urlopen(Request(url, headers=headers), timeout=30) as response:
            return response.read()
    commit = json.loads(read(f'https://api.github.com/repos/{repo}/commits/HEAD'))['sha']
    tree = json.loads(read(f'https://api.github.com/repos/{repo}/git/trees/{commit}?recursive=1'))
    if tree.get('truncated'):
        raise ValueError('Template tree is truncated; use sync --dir with a local checkout')
    paths = [item['path'] for item in tree['tree'] if item['type'] == 'blob' and is_shared(item['path'])]
    # Pin all file reads to the same commit to prevent mixed revisions.
    def file_bytes(path):
        from urllib.parse import quote
        return read(f'https://raw.githubusercontent.com/{repo}/{commit}/{quote(path)}')
    return paths, file_bytes, f'{repo}@{commit[:8]}'


def run_sync(root, arguments):
    parser = argparse.ArgumentParser(prog='dev.sh sync')
    parser.add_argument('direction', nargs='?', choices=('pull', 'push'), default='pull')
    parser.add_argument('--dir', help='Use a particular local template checkout')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--yes', '-y', action='store_true')
    args = parser.parse_args(arguments)
    root = Path(root).resolve()
    repo = configured_repo(root)
    clone = local_template(root, repo, args.dir)
    protected = sync_paths(root)
    if args.direction == 'push':
        if clone is None:
            raise ValueError('Template checkout not found; clone it beside this project or use sync push --dir')
        if clone == root:
            print('This is the template checkout; its shared changes are already here.')
            return 0
        destination = clone
        paths = shared_inventory(root)
        read = lambda path: (root / path).read_bytes()
        label = str(root)
        # Protect project-owned paths in both repositories in either direction.
        protected += sync_paths(clone)
    else:
        destination = root
        if clone == root:
            print('This is the template checkout; no self-sync is needed.')
            return 0
        if clone:
            paths = shared_inventory(clone)
            read = lambda path: (clone / path).read_bytes()
            label = str(clone)
            protected += sync_paths(clone)
        else:
            paths, read, label = remote_template(repo)
    print(f'Sync {args.direction}: {label} -> {destination}')
    actions = []
    for path in sorted(paths):
        if not is_shared(path, protected):
            continue
        target = destination / path
        content = read(path)
        previous = target.read_bytes() if target.is_file() else None
        if path.startswith('backend/requirements/') and path.endswith('.txt'):
            # On push, only the source core transfers; the template's extras stay local.
            content = merge_requirements(content, previous)
        if path == 'frontend/web/package.json':
            content = merge_web_package(content, previous)
        if content != previous:
            actions.append((path, content))
            print(f'  {"update" if previous is not None else "add"}: {path}')
    retired = set(RETIRED_SHARED_PATHS)
    if args.direction == 'push':
        retired |= tracked_shared_paths(root, deleted=True)
    else:
        # Remove obsolete tracked architecture files, preserving new local files
        # that have not yet been offered back to the template.
        retired |= tracked_shared_paths(destination) - set(paths)
    for path in sorted(retired):
        if any(path.startswith(prefix) if prefix.endswith('/') else path == prefix for prefix in protected):
            continue
        if (destination / path).is_file():
            # A customized legacy ML Dockerfile must be relocated before removal.
            if path.endswith('Dockerfile.ml-service') and not (destination / 'backend/ml_service/Dockerfile').is_file():
                actions.append(('backend/ml_service/Dockerfile', (destination / path).read_bytes()))
                print('  move: backend/config/Dockerfile.ml-service -> backend/ml_service/Dockerfile')
            actions.append((path, None))
            print(f'  remove retired: {path}')
    if not actions:
        print('Shared architecture is already up to date.')
        return 0
    if args.dry_run:
        print(f'Dry run: {len(actions)} changes; no files written.')
        return 0
    if not args.yes and input(f'Apply {len(actions)} shared changes? [y/N] ').strip().lower() not in {'y', 'yes'}:
        print('No changes applied.')
        return 0
    for path, content in actions:
        target = (destination / path).resolve()
        if not target.is_relative_to(destination):
            raise ValueError(f'Sync path escapes the checkout: {path}')
        if content is None:
            target.unlink()
            # Retired helpers may have been untracked. Prune only empty parent
            # directories so their former folder also disappears from checkouts.
            parent = target.parent
            while parent != destination:
                try:
                    parent.rmdir()
                except OSError:
                    break
                parent = parent.parent
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            if path.endswith('.sh'):
                target.chmod(target.stat().st_mode | 0o111)
    print(f'Applied {len(actions)} shared changes.')
    if args.direction == 'push':
        print(f'Review and commit the template changes in {destination}, then git push to publish them.')
    return 0


if __name__ == '__main__':
    root, option = sys.argv[1:3]
    if option == 'mobile-apps':
        print('\n'.join(mobile_apps(root)))
    elif option == 'sync-paths':
        print('\n'.join(sync_paths(root)))
    elif option == 'exposure-check-command':
        try:
            print('\n'.join(exposure_check_command(root)))
        except ValueError as error:
            print(f'Exposure refused: {error}', file=sys.stderr)
            raise SystemExit(1)
    elif option == 'has-exposure-check':
        raise SystemExit(0 if project_option(root, 'PUBLIC_EXPOSURE_CHECK_COMMAND', []) else 1)
    elif option == 'exposure-prepare-command':
        command = project_option(root, 'PUBLIC_EXPOSURE_PREPARE_COMMAND', [])
        if not isinstance(command, list) or any(not isinstance(arg, str) or not arg or '\n' in arg for arg in command):
            raise SystemExit('PUBLIC_EXPOSURE_PREPARE_COMMAND must be a literal argument list')
        print('\n'.join(command))
    elif option == 'sync-repo':
        print(configured_repo(root))
    elif option == 'check-isolation':
        try:
            check_project_isolation(root, sys.argv[3], sys.argv[4:])
        except (ValueError, OSError, subprocess.CalledProcessError) as error:
            print(f'Project isolation check failed: {error}', file=sys.stderr)
            raise SystemExit(1)
    elif option == 'has-dev-command':
        raise SystemExit(0 if sys.argv[3] in project_option(root, 'DEV_COMMANDS', {}) else 1)
    elif option == 'run-dev-command':
        command = project_option(root, 'DEV_COMMANDS', {}).get(sys.argv[3])
        if not command:
            raise SystemExit(f'Unknown project command: {sys.argv[3]}')
        environment = project_environment(root)
        os.environ.clear()
        os.environ.update(environment)
        sys.path.insert(0, str(Path(root).resolve() / 'backend'))
        namespace = runpy.run_path(str(Path(root).resolve() / 'backend/project.py'))
        handler = namespace.get(command)
        if not callable(handler):
            raise SystemExit(f'Project command handler is not callable: {command}')
        result = handler(*sys.argv[4:])
        raise SystemExit(result if isinstance(result, int) else 0)
    elif option == 'sync':
        try:
            raise SystemExit(run_sync(root, sys.argv[3:]))
        except (ValueError, OSError, subprocess.CalledProcessError) as error:
            print(f'Sync failed: {error}', file=sys.stderr)
            raise SystemExit(1)
    elif option == 'android-metadata':
        android_metadata(root, sys.argv[3])
    elif option == 'mobile-api-url':
        print(mobile_build_environment(root, sys.argv[3]).get('EXPO_PUBLIC_API_URL') or sys.argv[4])
    elif option == 'run-build':
        env = project_environment(root)
        env.update(mobile_build_environment(root, sys.argv[3]))
        raise SystemExit(subprocess.call(sys.argv[4:], env=env))
    elif option == 'bootstrap-env':
        bootstrap_environment(root)
    else:
        raise SystemExit(f'Unknown project option: {option}')
