"""Portable Expo store releases; app identities and credentials stay project-owned."""
import argparse
import copy
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import urlsplit

if __package__:
    from .project_config import environment_values, mobile_apps
else:
    from project_config import environment_values, mobile_apps

EAS_VERSION = '27.5.0'
STORE_PROFILES = ('production', 'testflight', 'playstore')


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def merge(base, override):
    result = copy.deepcopy(base)
    for key, value in override.items():
        result[key] = merge(result[key], value) if isinstance(value, dict) and isinstance(result.get(key), dict) else copy.deepcopy(value)
    return result


def profile(data, name, section='build', seen=()):
    if name in seen or len(seen) >= 5:
        raise ValueError('Cyclic or excessive EAS profile inheritance')
    if name not in data.get(section, {}):
        raise ValueError(f'Missing {section}.{name}; run store prepare first')
    current = copy.deepcopy(data[section][name])
    parent = current.pop('extends', None)
    return merge(profile(data, parent, section, (*seen, name)), current) if parent else current


def public_environment(root, existing):
    values = environment_values(root)
    public = dict(existing)
    # Only explicit production overrides replace an existing release setting.
    # Unsuffixed development URLs must never leak into a store build.
    for key, value in values.items():
        if key.startswith('EXPO_PUBLIC_') and value and not key.endswith(('_DEVELOPMENT', '_PRODUCTION')):
            if key not in ('EXPO_PUBLIC_ENV', 'EXPO_PUBLIC_API_URL', 'EXPO_PUBLIC_WS_URL'):
                public[key] = value
    for key, value in values.items():
        if key.startswith('EXPO_PUBLIC_') and key.endswith('_PRODUCTION') and value:
            public[key[:-len('_PRODUCTION')]] = value
    public['EXPO_PUBLIC_ENV'] = 'production'
    validate_url(public.get('EXPO_PUBLIC_API_URL', ''), 'https')
    if public.get('EXPO_PUBLIC_WS_URL'):
        validate_url(public['EXPO_PUBLIC_WS_URL'], 'wss')
    return public


def validate_url(value, scheme):
    url = urlsplit(value)
    host = (url.hostname or '').lower()
    invalid = (url.scheme != scheme or not host or url.username or url.password or url.query or url.fragment
               or host == 'localhost' or host.startswith('dev.') or host.endswith(('.localhost', '.local', '.internal', '.trycloudflare.com')))
    try:
        invalid = invalid or not ipaddress.ip_address(host).is_global
    except ValueError:
        invalid = invalid or '.' not in host
    if invalid:
        raise ValueError(f'Store builds require an explicit public {scheme} production URL; configure EXPO_PUBLIC_API_URL_PRODUCTION / EXPO_PUBLIC_WS_URL_PRODUCTION in the root .env')


def prepare(root, app_dir, dry_run=False):
    path = app_dir / 'eas.json'
    data = read_json(path) if path.exists() else {}
    old = profile(data, 'production') if 'production' in data.get('build', {}) else {}
    builds = data.setdefault('build', {})
    if old.get('distribution') == 'internal' and 'preview' not in builds:
        builds['preview'] = copy.deepcopy(old)
    production = merge(old, {
        'developmentClient': False, 'distribution': 'store', 'environment': 'production',
        'autoIncrement': True, 'env': public_environment(root, old.get('env', {})),
        'ios': {'simulator': False, 'buildConfiguration': 'Release'},
        'android': {'buildType': 'app-bundle', 'withoutCredentials': False},
    })
    production['ios'].pop('enterpriseProvisioning', None)
    # These custom tasks can silently override the store artifact/signing mode.
    production['android'].pop('gradleCommand', None)
    production['android'].pop('developmentClient', None)
    production['ios'].pop('developmentClient', None)
    builds['production'] = production
    for name in ('testflight', 'playstore'):
        builds[name] = {'extends': 'production'}
    if 'development-testflight' in builds:
        builds['development-testflight'] = {'extends': 'production'}
    data.setdefault('cli', {}).update({'version': EAS_VERSION, 'appVersionSource': 'remote'})
    submissions = data.setdefault('submit', {})
    ios = copy.deepcopy(submissions.get('production', {}).get('ios', {}))
    # Never propagate fabricated Apple identifiers from old scaffolding.
    for key in ('ascAppId', 'appleTeamId'):
        if str(ios.get(key, '')).lower() in ('placeholder', 'todo', 'changeme'):
            ios.pop(key)
    submissions['production'] = merge(submissions.get('production', {}), {
        'ios': ios, 'android': {'track': 'internal', 'releaseStatus': 'draft'},
    })
    submissions['production']['ios'] = ios
    submissions['testflight'] = {'extends': 'production'}
    submissions['playstore'] = {'extends': 'production'}
    submissions['android-production'] = {'extends': 'production', 'android': {'track': 'production', 'releaseStatus': 'draft'}}
    if 'development-testflight' in submissions:
        submissions['development-testflight'] = {'extends': 'production'}
    encoded = json.dumps(data, indent=2) + '\n'
    changed = not path.exists() or path.read_text(encoding='utf-8-sig') != encoded
    if changed and not dry_run:
        path.write_text(encoded, encoding='utf-8')
    print(f'{app_dir.name}: {"would update" if dry_run and changed else "updated" if changed else "unchanged"} store profiles')
    return data


def build_environment(root, build):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith('EXPO_PUBLIC_') and key not in ('DEV_MODE', 'CLOUDFLARE_TUNNEL_URL', 'GOOGLE_MAPS_API_KEY')}
    values = environment_values(root)
    if values.get('EXPO_TOKEN'):
        env['EXPO_TOKEN'] = values['EXPO_TOKEN']
    env.update(build.get('env', {}))
    env['EXPO_NO_DOTENV'] = '1'
    return env


def expo_config(app_dir, env):
    script = "const p=require.resolve('@expo/config',{paths:[process.cwd()]});process.stdout.write(JSON.stringify(require(p).getConfig(process.cwd(),{skipSDKVersionRequirement:true}).exp));"
    result = subprocess.run(['node', '-e', script], cwd=app_dir, env=env, text=True, capture_output=True)
    if result.returncode:
        raise ValueError('Unable to resolve Expo config. Install this app with npm ci and check app.config.js.')
    return json.loads(result.stdout)


def check(root, app_dir, name='production'):
    data = read_json(app_dir / 'eas.json')
    build = profile(data, name)
    if build.get('distribution') != 'store' or build.get('developmentClient') is not False:
        raise ValueError('Store profiles must use distribution=store and developmentClient=false')
    if build.get('environment') != 'production' or build.get('env', {}).get('EXPO_PUBLIC_ENV') != 'production':
        raise ValueError('Store builds must select the production environment and app identity')
    if data.get('cli', {}).get('appVersionSource') != 'remote' or build.get('autoIncrement') is not True:
        raise ValueError('Store builds need remote app versions and autoIncrement=true')
    if build.get('ios', {}).get('simulator') or build.get('ios', {}).get('enterpriseProvisioning'):
        raise ValueError('TestFlight needs a device App Store archive, not simulator/ad hoc provisioning')
    if build.get('ios', {}).get('buildConfiguration', 'Release') != 'Release':
        raise ValueError('Store iOS archives must use the Release configuration')
    android = build.get('android', {})
    if android.get('buildType') != 'app-bundle' or android.get('withoutCredentials') or android.get('gradleCommand'):
        raise ValueError('Google Play needs a signed app-bundle without a custom Gradle override')
    if any(build.get(platform, {}).get('developmentClient') for platform in ('ios', 'android')):
        raise ValueError('Platform settings must not enable the development client')
    for platform in ('ios', 'android'):
        overrides = build.get(platform, {})
        if overrides.get('env') or overrides.get('autoIncrement', True) is not True:
            raise ValueError('Keep store environment and autoIncrement in the common profile so both platforms match')
    expected = public_environment(root, build.get('env', {}))
    if expected != build.get('env', {}):
        raise ValueError('Root production environment changed; run store prepare before building')
    env = build_environment(root, build)
    config = expo_config(app_dir, env)
    project_id = config.get('extra', {}).get('eas', {}).get('projectId', '')
    if not re.fullmatch(r'[0-9a-fA-F-]{36}', project_id):
        raise ValueError('Link this app to its own EAS project first with eas init')
    for identifier in (config.get('ios', {}).get('bundleIdentifier', ''), config.get('android', {}).get('package', '')):
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+', identifier) or identifier.endswith(('.development', '.preview', '.staging')):
            raise ValueError('Both platforms need their production app identifiers in Expo config')
    if config.get('extra', {}).get('env', 'production') != 'production':
        raise ValueError('Resolved Expo config still selects a development environment')
    if config.get('extra', {}).get('apiUrl'):
        validate_url(config['extra']['apiUrl'], 'https')
    return data, config, env


def validate_submission(data, platform, name):
    submission = profile(data, name, 'submit')
    if platform == 'ios':
        if name == 'android-production':
            raise ValueError('android-production is only for Google Play')
        if not re.fullmatch(r'[0-9]+', str(submission.get('ios', {}).get('ascAppId', ''))):
            raise ValueError('Set this app\'s real submit.production.ios.ascAppId in eas.json before upload')
    else:
        android = submission.get('android', {})
        expected_track = 'production' if name == 'android-production' else 'internal'
        if android.get('track') != expected_track or android.get('releaseStatus') != 'draft':
            raise ValueError('Submit must target the selected Google Play track as a draft')


def validate_build(record, config, platform, build_id):
    expected_id = config['ios']['bundleIdentifier'] if platform == 'ios' else config['android']['package']
    expected = {'id': build_id, 'status': 'FINISHED', 'platform': platform.upper(),
                'distribution': 'STORE', 'appIdentifier': expected_id}
    if any(record.get(key) != value for key, value in expected.items()):
        raise ValueError('Selected build is unfinished or has the wrong platform, app identifier or distribution')
    if record.get('app', {}).get('id') != config['extra']['eas']['projectId'] or record.get('isForIosSimulator'):
        raise ValueError('Selected build belongs to another EAS project or is a simulator archive')
    if record.get('buildProfile') not in STORE_PROFILES or not record.get('appBuildVersion'):
        raise ValueError('Select a versioned production/testflight/playstore build')


def eas(app_dir, env, arguments, capture=False):
    npx = shutil.which('npx.cmd' if os.name == 'nt' else 'npx')
    if not npx:
        raise ValueError('Install Node.js and npm to run EAS')
    command = [npx, '--yes', f'eas-cli@{EAS_VERSION}', *arguments]
    result = subprocess.run(command, cwd=app_dir, env=env, text=True, capture_output=capture)
    if result.returncode:
        if capture and result.stderr:
            print(result.stderr, file=sys.stderr)
        raise ValueError(f'EAS {arguments[0]} failed (exit {result.returncode}); check EAS authentication and signing setup')
    return json.loads(result.stdout) if capture else None


def main(argv=None):
    parser = argparse.ArgumentParser(description='Standalone TestFlight / App Store and Google Play releases')
    parser.add_argument('root', type=Path)
    parser.add_argument('action', choices=('list', 'prepare', 'check', 'credentials', 'build', 'status', 'submit'))
    parser.add_argument('app', nargs='?')
    parser.add_argument('platform', nargs='?', choices=('ios', 'android'), default='ios')
    parser.add_argument('--profile', choices=STORE_PROFILES, default='production')
    parser.add_argument('--submit-profile', choices=(*STORE_PROFILES, 'android-production'), default='production')
    parser.add_argument('--id', help='Exact EAS build ID; never implicitly select the latest build')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--local', action='store_true', help='Build on this host (iOS requires macOS)')
    args = parser.parse_args(argv)
    root = args.root.resolve()
    apps = mobile_apps(root)
    if args.action == 'list':
        print('\n'.join(apps) if apps else 'No mobile apps in this project yet.')
        return 0
    matches = [name for name in apps if name.casefold() == (args.app or '').casefold()]
    if len(matches) != 1:
        raise ValueError('Select one exact app name from store list')
    app_dir = root / 'frontend/mobile' / matches[0]
    if args.action == 'prepare':
        prepare(root, app_dir, args.dry_run)
        return 0
    if args.action in ('submit', 'status') and not args.id:
        raise ValueError('An explicit --id EAS_BUILD_ID is required')
    if args.id and not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', args.id):
        raise ValueError('Invalid EAS build ID')
    data, config, env = check(root, app_dir, args.profile)
    summary = {'app': matches[0], 'profile': args.profile, 'ios': config['ios']['bundleIdentifier'],
               'android': config['android']['package'], 'version': config.get('version'),
               'projectId': config['extra']['eas']['projectId']}
    print(json.dumps(summary, indent=2), flush=True)
    if args.action == 'check':
        print('Local configuration passed. Store accounts, signing and device behavior still require verification.')
        if not profile(data, 'production', 'submit').get('ios', {}).get('ascAppId'):
            print('iOS upload pending: set submit.production.ios.ascAppId to this app\'s App Store Connect ID.')
        return 0
    if args.action == 'credentials':
        if args.dry_run:
            print(f'Would run: eas credentials --platform {args.platform}')
            return 0
        if not sys.stdin.isatty():
            raise ValueError('Run store credentials in an interactive terminal to configure this app\'s signing and upload credentials')
        eas(app_dir, env, ['credentials', '--platform', args.platform])
        return 0
    if args.action == 'build':
        if args.local and (os.name == 'nt' or (args.platform == 'ios' and sys.platform != 'darwin')):
            raise ValueError('Local iOS builds require macOS/Xcode; local Android requires macOS/Linux. Use cloud builds from Windows.')
        interactive = sys.stdin.isatty()
        command = ['build', '--platform', args.platform, '--profile', args.profile]
        command += ['--local'] if args.local else ['--no-wait']
        capture = not args.local and not interactive
        if capture:
            command += ['--json']
        if not interactive:
            command += ['--non-interactive']
        if args.dry_run:
            print('Would run: eas ' + ' '.join(command))
            return 0
        result = eas(app_dir, env, command, capture=capture)
        if result is not None:
            print(json.dumps([{key: item.get(key) for key in ('id', 'status', 'platform', 'buildProfile')} for item in result], indent=2))
        return 0
    if args.action == 'submit':
        validate_submission(data, args.platform, args.submit_profile)
    if args.dry_run:
        print(f'Would verify EAS build {args.id} against this app before {args.action}. No upload performed.')
        return 0
    record = eas(app_dir, env, ['build:view', args.id, '--json'], capture=True)
    if args.action == 'status':
        if record.get('app', {}).get('id') != summary['projectId']:
            raise ValueError('Build belongs to a different EAS project')
        print(json.dumps({key: record.get(key) for key in ('id', 'status', 'platform', 'appIdentifier', 'appVersion', 'appBuildVersion', 'buildProfile')}, indent=2))
        return 0
    validate_build(record, config, args.platform, args.id)
    eas(app_dir, env, ['submit', '--platform', args.platform, '--profile', args.submit_profile,
                       '--id', args.id, '--non-interactive', '--wait'])
    print('Upload completed. Verify Apple processing/TestFlight availability or the Google Play draft in the store console; public release is a separate step.')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'Mobile release: {error}', file=sys.stderr)
        raise SystemExit(1)
