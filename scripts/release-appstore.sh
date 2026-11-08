#!/bin/bash
# CI-only credentials wrapper; local export remains available in export-appstore.py.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
source scripts/environment.sh
test "${GITHUB_ACTIONS:-}" = true || { echo 'Run this credentials wrapper on GitHub Actions.' >&2; exit 1; }
test "$(uname -m)" = arm64 || { echo 'App Store releases require Apple Silicon.' >&2; exit 1; }
for variable in APPSTORE_DISTRIBUTION_P12 APPSTORE_INSTALLER_P12 APPSTORE_CERTIFICATE_PASSWORD APPSTORE_PROVISIONING_PROFILE APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_PRIVATE_KEY APP_STORE_APP_ID; do
  test -n "${!variable:-}" || { echo "Missing release credential: $variable" >&2; exit 1; }
done
umask 077
signing_dir=$(mktemp -d "$TMPDIR/prose-appstore.XXXXXX")
keychain="$signing_dir/signing.keychain-db"
security list-keychains -d user > "$signing_dir/keychains.txt"
set_keychains() {
  python3 - "$signing_dir/keychains.txt" "$@" <<'PY'
import pathlib, shlex, subprocess, sys
original = shlex.split(pathlib.Path(sys.argv[1]).read_text())
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *sys.argv[2:], *original], check=True)
PY
}
cleanup() {
  set_keychains >/dev/null 2>&1 || true
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$signing_dir"
}
trap cleanup EXIT
python3 - "$signing_dir" <<'PY'
import base64, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
for secret, name in [('APPSTORE_DISTRIBUTION_P12', 'distribution.p12'),
                     ('APPSTORE_INSTALLER_P12', 'installer.p12'),
                     ('APPSTORE_PROVISIONING_PROFILE', 'profile.provisionprofile')]:
    (root / name).write_bytes(base64.b64decode(os.environ[secret], validate=True))
(root / 'api.p8').write_text(os.environ['APP_STORE_CONNECT_PRIVATE_KEY'])
PY
unset APPSTORE_DISTRIBUTION_P12 APPSTORE_INSTALLER_P12 APPSTORE_PROVISIONING_PROFILE APP_STORE_CONNECT_PRIVATE_KEY
python3 scripts/appstore_connect.py preflight --key "$signing_dir/api.p8"
python3 scripts/appstore_connect.py claim --key "$signing_dir/api.p8"
keychain_password=$(openssl rand -base64 32)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
curl --fail --silent --show-error --location --proto '=https' \
  https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$signing_dir/WWDR.cer"
printf '%s  %s\n' dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f "$signing_dir/WWDR.cer" | shasum -a 256 -c -
security import "$signing_dir/WWDR.cer" -k "$keychain" >/dev/null
security import "$signing_dir/distribution.p12" -k "$keychain" -P "$APPSTORE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
security import "$signing_dir/installer.p12" -k "$keychain" -P "$APPSTORE_CERTIFICATE_PASSWORD" -T /usr/bin/productbuild >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$keychain_password" "$keychain" >/dev/null
unset APPSTORE_CERTIFICATE_PASSWORD
set_keychains "$keychain"
distribution=$(security find-identity -v -p codesigning "$keychain" | awk '/"Apple Distribution:|"3rd Party Mac Developer Application:/ {print $2}')
installer=$(security find-identity -v -p basic "$keychain" | awk '/"3rd Party Mac Developer Installer:/ {print $2}')
for identity in "$distribution" "$installer"; do
  test "$(printf '%s\n' "$identity" | awk 'NF {n++} END {print n+0}')" = 1 || { echo 'Expected one valid identity of each certificate type.' >&2; exit 1; }
done
export PROSE_DISTRIBUTION=appstore
scripts/build.sh release
python3 scripts/export-appstore.py --profile "$signing_dir/profile.provisionprofile" \
  --identity "$distribution" --installer-identity "$installer" --keychain "$keychain"
python3 - <<'PY'
import json, plistlib
from pathlib import Path
expected = json.loads(Path('build/release-metadata.json').read_text())
actual = plistlib.loads(Path('build/Prose.app/Contents/Info.plist').read_bytes())
for key, field in [('CFBundleShortVersionString', 'version'), ('CFBundleVersion', 'build'), ('ProseCommit', 'commit')]:
    if actual[key] != expected[field]:
        raise SystemExit('Packaged app differs from the tag: ' + key)
if actual.get('ITSAppUsesNonExemptEncryption') is not False:
    raise SystemExit('Packaged app is missing the OS-native encryption declaration')
PY
python3 scripts/appstore_connect.py upload --key "$signing_dir/api.p8"
python3 scripts/appstore_connect.py submit --key "$signing_dir/api.p8"
python3 - <<'PY' >> "$GITHUB_STEP_SUMMARY"
import json
from pathlib import Path
meta = json.loads(Path('build/release-metadata.json').read_text())
result = json.loads(Path('build/appstore-submission.json').read_text())
print(f"App Store: **{meta['version']} ({meta['build']})**, commit `{meta['commit']}`.")
print('Apple state: ' + str(result['attributes'].get('state', result['attributes'].get('appVersionState'))))
print('Automatic release after approval. Global free pricing is retained.')
PY
