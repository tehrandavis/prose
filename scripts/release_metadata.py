"""One version and one English release message for both release channels."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
VERSION = r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
LOCALES = ('en-US',)


def parse_notes(text):
    sections = re.split(r'^## (\S+)\s*$', text, flags=re.MULTILINE)
    if sections[0].strip() or len(sections) != 3 or tuple(sections[1::2]) != LOCALES:
        raise ValueError('Release notes need exactly one ## en-US section')
    notes = dict(zip(sections[1::2], (body.strip() for body in sections[2::2])))
    for locale, body in notes.items():
        if not body or len(body) > 4000 or re.search(r'\bTODO\b', body, flags=re.IGNORECASE):
            raise ValueError(f'{locale}: provide final release notes, 1–4000 characters, without TODO')
        if re.search(r'^#|\[.+\]\(|```|\*\*|<[^>]+>', body, flags=re.MULTILINE):
            raise ValueError(f'{locale}: use plain text and bullet points for App Store release notes')
    return notes


def metadata(root, tag):
    if not re.fullmatch('v' + VERSION, tag):
        raise ValueError('A stable release tag must be vMAJOR.MINOR.PATCH')
    info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if tag != 'v' + version:
        raise ValueError('Tag and Resources/Info.plist version differ')
    if not re.fullmatch(r'[1-9][0-9]{0,3}', build):
        raise ValueError('CFBundleVersion must be an integer from 1 to 9999')
    text = (root / 'releases' / (version + '.md')).read_text()
    return {'version': version, 'build': build, 'tag': tag, 'notes': parse_notes(text)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    prepare = sub.add_parser('prepare', help='Bump both versions and create a notes draft; never tags or publishes')
    prepare.add_argument('version')
    check = sub.add_parser('check')
    check.add_argument('tag')
    check.add_argument('--output', type=Path, default=ROOT / 'build/release-metadata.json')
    args = parser.parse_args()
    if args.command == 'prepare':
        if not re.fullmatch(VERSION, args.version):
            raise ValueError('Use MAJOR.MINOR.PATCH')
        path = ROOT / 'Resources/Info.plist'
        info = plistlib.loads(path.read_bytes())
        if tuple(map(int, args.version.split('.'))) <= tuple(map(int, info['CFBundleShortVersionString'].split('.'))):
            raise ValueError('The next version must increase')
        build = int(info['CFBundleVersion']) + 1
        if build > 9999:
            raise ValueError('Build number exceeds the integer policy; update the policy before releasing')
        notes = ROOT / 'releases' / (args.version + '.md')
        notes.parent.mkdir(exist_ok=True)
        # Exclusive creation avoids overwriting an existing release message.
        with notes.open('x') as file:
            file.write('## en-US\n\nTODO: describe the changes for users.\n')
        text = path.read_text().replace('<string>' + info['CFBundleShortVersionString'] + '</string>',
                                        '<string>' + args.version + '</string>', 1)
        text = re.sub(r'(<key>CFBundleVersion</key>\s*<string>)[^<]+', r'\g<1>' + str(build), text)
        path.write_text(text)
        print(f'Prepared {args.version} ({build}); finish {notes.relative_to(ROOT)} before merging and tagging')
        return
    result = metadata(ROOT, args.tag)
    subprocess.run(['git', 'merge-base', '--is-ancestor', 'HEAD', 'origin/main'], cwd=ROOT, check=True)
    # A tag must identify this checkout even for a manual retry.
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    tagged = subprocess.check_output(['git', 'rev-parse', args.tag + '^{commit}'], cwd=ROOT, text=True).strip()
    if head != tagged:
        raise ValueError('Checkout does not match the requested tag')
    result['commit'] = head
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    args.output.with_suffix('.md').write_text((ROOT / 'releases' / (result['version'] + '.md')).read_text())
    print(f"Validated {args.tag}, build {result['build']}, commit {head}")


if __name__ == '__main__':
    main()
