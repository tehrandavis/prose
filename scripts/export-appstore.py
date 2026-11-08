#!/usr/bin/env python3
"""Validate a Mac App Store profile, sign the app and create its installer."""
import argparse
import datetime
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess


def run(*args):
    return subprocess.check_output(args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('build/Prose.app'))
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--installer-identity', required=True)
    parser.add_argument('--keychain', required=True)
    parser.add_argument('--output', type=Path, default=Path('build/Prose-AppStore.pkg'))
    args = parser.parse_args()
    info_path = args.app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(args.profile)))
    allowed = profile['Entitlements']
    team = profile['TeamIdentifier'][0]
    app_id = team + '.' + info['CFBundleIdentifier']
    if info.get('ProseDistribution') != 'appstore':
        raise ValueError('Build with PROSE_DISTRIBUTION=appstore first')
    if (profile.get('Platform') != ['OSX'] or profile.get('ProvisionedDevices')
            or profile.get('ProvisionsAllDevices') or allowed.get('get-task-allow')
            or profile['ExpirationDate'] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
            or allowed.get('com.apple.application-identifier') != app_id):
        raise ValueError('Expected a current Mac App Store profile matching this app')
    certs = [hashlib.sha1(cert).hexdigest().upper() for cert in profile['DeveloperCertificates']]
    if args.identity.upper() not in certs:
        raise ValueError('--identity must be the SHA-1 of a certificate included in the profile')
    entitlements = plistlib.loads(Path('Resources/Prose.AppStore.entitlements').read_bytes())
    cloud = plistlib.loads(Path('Resources/Prose.iCloud.entitlements.example').read_bytes())
    cloud['com.apple.developer.ubiquity-kvstore-identifier'] = app_id
    for key, value in cloud.items():
        permitted = allowed.get(key)
        if permitted == '*':
            continue
        requested = value if isinstance(value, list) else [value]
        options = permitted if isinstance(permitted, list) else [permitted]
        if not all(any(isinstance(option, str) and (item == option or
                       (option.endswith('*') and item.startswith(option[:-1])))
                       for option in options) for item in requested):
            raise ValueError('Profile does not authorize ' + key)
    entitlements.update(cloud)
    entitlements.update({'com.apple.application-identifier': app_id,
                         'com.apple.developer.team-identifier': team})
    entitlement_path = args.output.parent / 'appstore-entitlements.plist'
    entitlement_path.parent.mkdir(parents=True, exist_ok=True)
    entitlement_path.write_bytes(plistlib.dumps(entitlements))
    info['LSApplicationCategoryType'] = 'public.app-category.productivity'
    info['CFBundleSupportedPlatforms'] = ['MacOSX']
    info['DTPlatformName'] = 'macosx'
    info['DTSDKName'] = 'macosx' + run('xcrun', '--sdk', 'macosx', '--show-sdk-version').decode().strip()
    info['DTSDKBuild'] = run('xcrun', '--sdk', 'macosx', '--show-sdk-build-version').decode().strip()
    info_path.write_bytes(plistlib.dumps(info))
    embedded_profile = args.app / 'Contents/embedded.provisionprofile'
    shutil.copyfile(args.profile, embedded_profile)
    embedded_profile.chmod(0o644)
    subprocess.run(['bash', 'scripts/sign-app.sh', str(args.app), args.identity,
                    args.keychain, str(entitlement_path)], check=True)
    subprocess.run(['productbuild', '--component', str(args.app), '/Applications',
                    '--sign', args.installer_identity, '--keychain', args.keychain,
                    str(args.output)], check=True)
    subprocess.run(['pkgutil', '--check-signature', str(args.output)], check=True)
    print(args.output)


if __name__ == '__main__':
    main()
