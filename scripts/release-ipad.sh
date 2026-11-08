#!/bin/bash
# Build and submit an immutable iPad release; prepare the first subscription review.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
source scripts/environment.sh
test "${GITHUB_ACTIONS:-}" = true || { echo 'Run this signing wrapper on GitHub Actions.' >&2; exit 1; }
for variable in APPSTORE_DISTRIBUTION_P12 APPSTORE_CERTIFICATE_PASSWORD APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_PRIVATE_KEY APP_STORE_APP_ID RELEASE_TAG; do
  test -n "${!variable:-}" || { echo "Missing iPad release setting: $variable" >&2; exit 1; }
done
python3 scripts/ipad_release.py --tag "$RELEASE_TAG"
python3 scripts/ipad_release.py --tag "$RELEASE_TAG" --wait-for-ci 2700
umask 077
signing_dir=$(mktemp -d "$TMPDIR/prose-ipad-signing.XXXXXX")
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
  if [ -n "${profile_path:-}" ]; then rm -f "$profile_path"; fi
  rm -rf "$signing_dir"
}
trap cleanup EXIT
python3 - "$signing_dir" <<'PY'
import base64, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
for secret, name in [('APPSTORE_DISTRIBUTION_P12', 'distribution.p12')]:
    (root / name).write_bytes(base64.b64decode(os.environ[secret], validate=True))
if os.environ.get('IPAD_APPSTORE_PROVISIONING_PROFILE'):
    (root / 'profile.mobileprovision').write_bytes(base64.b64decode(os.environ['IPAD_APPSTORE_PROVISIONING_PROFILE'], validate=True))
(root / 'api.p8').write_text(os.environ['APP_STORE_CONNECT_PRIVATE_KEY'])
PY
unset APPSTORE_DISTRIBUTION_P12 IPAD_APPSTORE_PROVISIONING_PROFILE APP_STORE_CONNECT_PRIVATE_KEY
apple=(python3 scripts/appstore_connect.py --platform IOS --metadata build/iPad-release/source.json --key "$signing_dir/api.p8")
"${apple[@]}" preflight
"${apple[@]}" claim
keychain_password=$(openssl rand -base64 32)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
curl --fail --silent --show-error --location --proto '=https' \
  https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$signing_dir/WWDR.cer"
printf '%s  %s\n' dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f "$signing_dir/WWDR.cer" | shasum -a 256 -c -
security import "$signing_dir/WWDR.cer" -k "$keychain" >/dev/null
security import "$signing_dir/distribution.p12" -k "$keychain" -P "$APPSTORE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$keychain_password" "$keychain" >/dev/null
unset APPSTORE_CERTIFICATE_PASSWORD
set_keychains "$keychain"
identity=$(security find-identity -v -p codesigning "$keychain" | awk '/"Apple Distribution:/ {print $2}')
test "$(printf '%s\n' "$identity" | awk 'NF {n++} END {print n+0}')" = 1 || { echo 'Expected one Apple Distribution identity for iPad.' >&2; exit 1; }
if [ ! -f "$signing_dir/profile.mobileprovision" ]; then
  "${apple[@]}" profile --identity "$identity" --profile-output "$signing_dir/profile.mobileprovision"
fi
python3 scripts/ipad_release.py --tag "$RELEASE_TAG" --profile "$signing_dir/profile.mobileprovision" --identity "$identity"
security cms -D -i "$signing_dir/profile.mobileprovision" > "$signing_dir/profile.plist"
team=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$signing_dir/profile.plist")
profile_uuid=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$signing_dir/profile.plist")
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$profiles"
profile_destination="$profiles/$profile_uuid.mobileprovision"
test ! -e "$profile_destination" || { echo 'Refusing to overwrite an existing signing profile.' >&2; exit 1; }
profile_path="$profile_destination"
cp "$signing_dir/profile.mobileprovision" "$profile_path"
scripts/build-ipad.sh device
env -u CC -u CXX xcodebuild -project iPad/Prose.xcodeproj -scheme Prose-iPad \
  -destination 'generic/platform=iOS' -derivedDataPath build/iPad \
  -clonedSourcePackagesDirPath .build/xcode-packages \
  -archivePath build/iPad-release/Prose.xcarchive \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY="$identity" \
  PROSE_IPAD_PROVISIONING_PROFILE="$profile_uuid" OTHER_CODE_SIGN_FLAGS="--keychain $keychain" archive
python3 scripts/ipad_release.py --tag "$RELEASE_TAG" --archive build/iPad-release/Prose.xcarchive
python3 - "$signing_dir/export.plist" "$team" "$identity" "$profile_uuid" <<'PY'
import pathlib, plistlib, sys
path, team, identity, profile = sys.argv[1:]
pathlib.Path(path).write_bytes(plistlib.dumps({
    'method': 'app-store-connect', 'destination': 'export', 'signingStyle': 'manual',
    'teamID': team, 'signingCertificate': identity,
    'provisioningProfiles': {'com.tehrandavis.prose': profile},
    'manageAppVersionAndBuildNumber': False, 'uploadSymbols': True,
    'iCloudContainerEnvironment': 'Production',
}))
PY
xcodebuild -exportArchive -archivePath build/iPad-release/Prose.xcarchive \
  -exportPath build/iPad-release/export -exportOptionsPlist "$signing_dir/export.plist"
"${apple[@]}" upload --package build/iPad-release/export/Prose.ipa
if ! "${apple[@]}" submit; then
  "${apple[@]}" status > build/iPad-release/apple-status.json || true
  if [ -f build/iPad-release/review-prepared.json ]; then
    printf '%s\n' 'iPad build and first subscription are prepared. Apple requires the initial review submission through App Store Connect. See review-prepared.json in the workflow artifact.' >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi
"${apple[@]}" status > build/iPad-release/apple-status.json
printf '%s\n' 'iPad build uploaded, processed and submitted to App Review. Submission proof is in the workflow artifact.' >> "$GITHUB_STEP_SUMMARY"
