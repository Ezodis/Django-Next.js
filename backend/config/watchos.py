"""Generic native watchOS builds; app metadata belongs in project.py."""
import argparse
import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

try:
    from .project_config import environment_values, project_option
except ImportError:
    from project_config import environment_values, project_option


def app_settings(root, name):
    apps = project_option(root, 'WATCHOS_APPS', {})
    matches = [config for key, config in apps.items() if key.casefold() == name.casefold()]
    if len(matches) != 1:
        raise ValueError(f'Unknown watch app: {name}. Available: {", ".join(apps) or "none"}')
    config = matches[0]
    directory = (root / config['path']).resolve()
    if not directory.is_relative_to(root.resolve()) or not directory.is_dir():
        raise ValueError('Watch app path must be an existing directory inside the project')
    if not config.get('scheme') or not config.get('bundle_id'):
        raise ValueError('Watch app requires scheme and bundle_id in WATCHOS_APPS')
    return config, directory


def public_configuration(root, profile):
    values = environment_values(root)
    if profile == 'production':
        web = values.get('WATCH_WEB_URL_PRODUCTION') or values.get('EXPO_PUBLIC_API_URL_PRODUCTION')
    else:
        web = values.get('WATCH_WEB_URL') or values.get('CLOUDFLARE_TUNNEL_URL')
    if not web:
        raise ValueError(f'Set WATCH_WEB_URL{"_PRODUCTION" if profile == "production" else ""} in the root .env (an HTTPS web origin)')
    parsed = urlsplit(web)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or parsed.query or parsed.fragment or parsed.path.rstrip('/') not in ('', '/api')):
        raise ValueError('Watch URL must be an HTTPS origin, optionally ending in /api, without credentials')
    origin = urlunsplit((parsed.scheme, parsed.netloc, '', '', ''))
    return {'profile': profile, 'webURL': origin, 'apiURL': origin + '/api'}


def simulator_id(devices, selected=None):
    watches = [device for runtime, entries in devices['devices'].items()
               if '.watchOS-' in runtime for device in entries if device.get('isAvailable')]
    if selected:
        watches = [device for device in watches if device['udid'] == selected]
    if not watches:
        raise ValueError('No available watchOS simulator. Install a watchOS runtime in Xcode Settings > Components.')
    return next((device['udid'] for device in watches if device['state'] == 'Booted'), watches[0]['udid'])


def run(*arguments, **kwargs):
    subprocess.run(list(arguments), check=True, **kwargs)


def build(root, args, config, directory):
    public = public_configuration(root, args.profile)
    generated = directory / '.generated'
    generated.mkdir(exist_ok=True)
    (generated / 'WatchConfiguration.json').write_text(json.dumps(public, indent=2) + '\n')
    if (directory / 'project.yml').is_file():
        if not shutil.which('xcodegen'):
            raise ValueError('Install XcodeGen on your Mac: brew install xcodegen')
        run('xcodegen', 'generate', '--spec', str(directory / 'project.yml'), cwd=directory)
    projects = sorted(directory.glob('*.xcworkspace')) or sorted(directory.glob('*.xcodeproj'))
    if len(projects) != 1:
        raise ValueError('Expected exactly one Xcode workspace or project in the watch app directory')
    project = projects[0]
    project_flag = '-workspace' if project.suffix == '.xcworkspace' else '-project'
    output = root / 'frontend/mobile/builds' / config['scheme'] / 'watchos'
    output.mkdir(parents=True, exist_ok=True)
    common = ['xcodebuild', project_flag, str(project), '-scheme', config['scheme']]
    team = environment_values(root).get('WATCH_DEVELOPMENT_TEAM')
    if team:
        common.append(f'DEVELOPMENT_TEAM={team}')
    if args.profile == 'production':
        archive = output / 'production.xcarchive'
        run(*common, '-configuration', 'Release', '-destination', 'generic/platform=watchOS',
            '-archivePath', str(archive), 'archive', cwd=directory)
        print(f'Archive: {archive}\nOpen in Xcode Organizer to validate and distribute; signing must be configured in Xcode.')
    elif args.device:
        # A physical Watch needs a signed device build. The Watch must already
        # be paired with this Mac in Xcode and have Developer Mode enabled.
        device_output = output / 'development-device'
        run(*common, '-configuration', 'Debug', '-sdk', 'watchos',
            '-destination', f'id={args.device}',
            '-derivedDataPath', str(device_output), 'CODE_SIGNING_ALLOWED=YES', 'build', cwd=directory)
        print(f'Device build ready: {device_output}')
    else:
        run(*common, '-configuration', 'Debug', '-sdk', 'watchsimulator',
            '-destination', 'generic/platform=watchOS Simulator',
            '-derivedDataPath', str(output / 'development'), 'CODE_SIGNING_ALLOWED=NO', 'build', cwd=directory)
        print(f'Simulator build ready. Run: ./dev.sh watchos "{args.app}"')


def launch(root, args, config):
    build_name = 'development-device' if args.device else 'development'
    output = root / 'frontend/mobile/builds' / config['scheme'] / f'watchos/{build_name}/Build/Products'
    candidates = []
    product_directory = 'Debug-watchos' if args.device else 'Debug-watchsimulator'
    for application in output.glob(f'{product_directory}/*.app'):
        with (application / 'Info.plist').open('rb') as source:
            info = plistlib.load(source)
        if info.get('CFBundleIdentifier') == config['bundle_id']:
            candidates.append(application)
    if len(candidates) != 1:
        target = f' --device {args.device}' if args.device else ''
        raise ValueError(f'Build the app first: ./dev.sh build "{args.app}" watchos development local{target}')
    if args.device:
        run('xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.device, str(candidates[0]))
        run('xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
            '--terminate-existing', config['bundle_id'])
        return
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
    device = simulator_id(devices, args.simulator)
    state = next(item['state'] for entries in devices['devices'].values() for item in entries if item['udid'] == device)
    if state != 'Booted':
        run('xcrun', 'simctl', 'boot', device)
    run('xcrun', 'simctl', 'bootstatus', device, '-b')
    run('open', '-a', 'Simulator', '--args', '-CurrentDeviceUDID', device)
    run('xcrun', 'simctl', 'install', device, str(candidates[0]))
    run('xcrun', 'simctl', 'launch', '--terminate-running-process', device, config['bundle_id'])


def main(root, arguments):
    parser = argparse.ArgumentParser(description='Native watchOS builds and simulator installation (macOS only).')
    commands = parser.add_subparsers(dest='command', required=True)
    builder = commands.add_parser('build')
    builder.add_argument('app')
    builder.add_argument('platform', choices=['watchos'])
    builder.add_argument('profile', choices=['development', 'production'], nargs='?', default='development')
    builder.add_argument('local', choices=['local'])
    builder.add_argument('--device', help='Build for a physical Watch UDID or CoreDevice identifier')
    launcher = commands.add_parser('watchos')
    launcher.add_argument('app')
    launcher.add_argument('--device', help='Physical Watch UDID or CoreDevice identifier')
    launcher.add_argument('--simulator', help='Select a particular watchOS simulator UDID')
    args = parser.parse_args(arguments)
    if sys.platform != 'darwin':
        raise ValueError('watchOS builds and simulators require macOS and full Xcode; Metro cannot run watchOS apps.')
    if not shutil.which('xcodebuild') or not shutil.which('xcrun'):
        raise ValueError('Install full Xcode and select its developer directory before using watchOS commands')
    config, directory = app_settings(root, args.app)
    if args.command == 'build':
        build(root, args, config, directory)
    else:
        launch(root, args, config)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main(Path(sys.argv[1]).resolve(), sys.argv[2:]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'watchOS: {error}', file=sys.stderr)
        raise SystemExit(1)
