"""Publish an unsigned IPA and advance the AltStore source after upload succeeds."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile

REPO = 'Ssrrrnn/companion-ios'
BUNDLE = 'com.ssrrrnn.companion'
SOURCE = Path('altstore-source.json')
CODE_PATHS = ['ios', '.github/workflows/build-ios.yml', 'scripts/publish_altstore.py', 'RELEASE_NOTES.txt']


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def ipa_metadata(ipa):
    privacy = {}
    with zipfile.ZipFile(ipa) as archive:
        bad = archive.testzip()
        if bad:
            raise ValueError(f'Corrupt IPA entry: {bad}')
        names = archive.namelist()
        main = [n for n in names if re.fullmatch(r'Payload/[^/]+\.app/Info.plist', n)]
        if len(main) != 1:
            raise ValueError('Expected one app in Payload')
        info = plistlib.loads(archive.read(main[0]))
        if info.get('CFBundleIdentifier') != BUNDLE:
            raise ValueError('Unexpected bundle identifier')
        for name in names:
            if re.search(r'\.(app|appex)/Info.plist$', name):
                data = plistlib.loads(archive.read(name))
                for key, value in data.items():
                    if key.endswith('UsageDescription'):
                        privacy[key] = str(value)
        # This pipeline deliberately distributes unsigned apps for local AltStore signing.
        # Do not silently publish a signed binary with uninspected entitlements.
        if any('/_CodeSignature/' in n for n in names):
            raise ValueError('Expected unsigned IPA; review signed entitlements first')
        entitlements = set()
        for path in Path('ios').rglob('*.entitlements'):
            data = plistlib.loads(path.read_bytes())
            entitlements.update(data)
        entitlements.difference_update({'application-identifier', 'com.apple.developer.team-identifier'})
        version = str(info['CFBundleShortVersionString'])
        build = str(info['CFBundleVersion'])
        for value in (version, build):
            if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', value):
                raise ValueError('Invalid app version/build')
    return {
        'version': version, 'buildVersion': build,
        'minOSVersion': str(info['MinimumOSVersion']), 'size': ipa.stat().st_size,
    }, {'entitlements': sorted(entitlements), 'privacy': privacy}


def update_source(source, version, permissions):
    apps = [a for a in source['apps'] if a['bundleIdentifier'] == BUNDLE]
    if len(apps) != 1:
        raise ValueError('Source must contain exactly one matching app')
    app = apps[0]
    old = app['versions']
    app['versions'] = [version] + [v for v in old if (v['version'], v.get('buildVersion')) != (version['version'], version['buildVersion'])][:19]
    # Permissions must also cover older versions still listed in this source.
    previous = app['appPermissions']
    app['appPermissions'] = {
        'entitlements': sorted(set(previous['entitlements']) | set(permissions['entitlements'])),
        'privacy': {**previous['privacy'], **permissions['privacy']},
    }
    return source


def fresh_main(build_sha):
    run('git', 'fetch', 'origin', 'main')
    # A build queued before newer client changes may have a release, but must not
    # replace the source's newest client. Source-only bot commits are harmless.
    changed = run('git', 'diff', '--name-only', build_sha, 'origin/main', '--', *CODE_PATHS)
    if changed:
        raise RuntimeError('Newer client code is on main; keeping source unchanged')
    run('git', 'checkout', '-B', 'altstore-publish', 'origin/main')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--validate-only', action='store_true')
    args = parser.parse_args()
    ipa = args.ipa.resolve()
    version, permissions = ipa_metadata(ipa)
    notes = Path('RELEASE_NOTES.txt').read_text().strip()
    version['localizedDescription'] = notes
    if args.validate_only:
        print(json.dumps({'metadata': version, 'permissions': permissions}, ensure_ascii=False))
        return
    if os.environ.get('GITHUB_REPOSITORY') != REPO:
        raise RuntimeError('This publisher is restricted to the public client repository')
    repo = json.loads(run('gh', 'api', f'repos/{REPO}'))
    if repo['private']:
        raise RuntimeError('Refusing to publish from a private repository')
    build_sha = run('git', 'rev-parse', 'HEAD')
    fresh_main(build_sha)
    tag = f"v{version['version']}-build{version['buildVersion']}"
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', suffix='.txt') as file:
        file.write(notes + '\n')
        file.flush()
        run('gh', 'release', 'create', tag, str(ipa), '--repo', REPO,
            '--target', build_sha, '--title', f"小家 {version['version']} ({version['buildVersion']})",
            '--notes-file', file.name)
    release = json.loads(run('gh', 'api', f'repos/{REPO}/releases/tags/{tag}'))
    assets = [a for a in release['assets'] if a['name'] == ipa.name and a['state'] == 'uploaded']
    if len(assets) != 1 or assets[0]['size'] != version['size']:
        raise RuntimeError('Uploaded IPA size does not match; source not changed')
    version['downloadURL'] = assets[0]['browser_download_url']
    version['date'] = release['published_at'] or dt.datetime.now(dt.timezone.utc).isoformat()
    # Retry only fast-forward races. Each attempt reads the latest source first.
    for attempt in range(3):
        fresh_main(build_sha)
        source = update_source(json.loads(SOURCE.read_text()), version, permissions)
        SOURCE.write_text(json.dumps(source, ensure_ascii=False, indent=2) + '\n')
        run('git', 'config', 'user.name', 'github-actions[bot]')
        run('git', 'config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com')
        run('git', 'add', str(SOURCE))
        run('git', 'commit', '-m', f"Publish AltStore {version['version']} ({version['buildVersion']})")
        result = subprocess.run(['git', 'push', 'origin', 'HEAD:main'], check=False)
        if result.returncode == 0:
            print('Published source: https://raw.githubusercontent.com/' + REPO + '/main/altstore-source.json')
            return
    raise RuntimeError('Source push failed; release remains available for recovery')


if __name__ == '__main__':
    main()
