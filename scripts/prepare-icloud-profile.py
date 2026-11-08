#!/usr/bin/env python3
"""Validate a Developer ID profile and derive only Prose's required entitlements."""
import argparse
import datetime
import hashlib
from pathlib import Path
import plistlib
import subprocess


def entitlements(profile, team, identity, now, app='com.tehrandavis.prose'):
    if app not in ('com.tehrandavis.prose', 'com.tehrandavis.prose.preview'):
        raise ValueError('Unsupported Prose application identity.')
    container = 'iCloud.com.tehrandavis.prose'
    if profile.get('TeamIdentifier') != [team]:
        raise ValueError('Provisioning profile team does not match signing team.')
    if profile.get('ExpirationDate', datetime.datetime.min) <= now:
        raise ValueError('Provisioning profile has expired.')
    if profile.get('ProvisionsAllDevices') is not True or profile.get('ProvisionedDevices'):
        raise ValueError('Expected a Developer ID distribution profile.')
    certificates = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])}
    if identity.upper() not in certificates:
        raise ValueError('Signing certificate is not authorized by this profile.')
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    if len(prefixes) != 1:
        raise ValueError('Expected one application identifier prefix.')
    prefix = prefixes[0]
    expected = {
        'com.apple.application-identifier': f'{prefix}.{app}',
        'com.apple.developer.team-identifier': team,
        'com.apple.developer.icloud-container-identifiers': [container],
        'com.apple.developer.ubiquity-container-identifiers': [container],
        'com.apple.developer.icloud-services': ['CloudDocuments'],
        'com.apple.developer.icloud-container-environment': 'Production',
        'com.apple.developer.ubiquity-kvstore-identifier': f'{prefix}.com.tehrandavis.prose',
    }
    allowed = profile.get('Entitlements', {})
    for key, requested in expected.items():
        permitted = allowed.get(key)
        if isinstance(requested, list):
            valid = permitted == '*' or (isinstance(permitted, list) and all(value in permitted or '*' in permitted for value in requested))
        else:
            valid = permitted == requested or (isinstance(permitted, str) and permitted.endswith('*') and requested.startswith(permitted[:-1]))
        if not valid:
            raise ValueError(f'Profile does not authorize required entitlement: {key}')
    if allowed.get('get-task-allow') or allowed.get('com.apple.security.get-task-allow'):
        raise ValueError('A public release must not allow debugger attachment.')
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', choices=['com.tehrandavis.prose', 'com.tehrandavis.prose.preview'], default='com.tehrandavis.prose')
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    decoded = subprocess.check_output(['security', 'cms', '-D', '-i', str(args.profile)], stderr=subprocess.DEVNULL)
    profile = plistlib.loads(decoded)
    result = entitlements(profile, args.team, args.identity, datetime.datetime.utcnow(), args.app)
    args.output.write_bytes(plistlib.dumps(result))
    print('Validated Developer ID profile for Prose iCloud Documents and preferences.')


if __name__ == '__main__':
    main()
