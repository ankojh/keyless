#!/usr/bin/env bash
# Builds build/Keyless.app from the Swift package.
#
# KEYLESS_SIGN_IDENTITY  codesigning identity. Defaults to the local self-signed "Keyless Local Dev"
#                        if it's in the keychain, else ad-hoc "-". With ad-hoc signing macOS treats
#                        every rebuild as a new app, so Accessibility must be re-granted.
# KEYLESS_CONFIG         debug or release (default: release)
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
config="${KEYLESS_CONFIG:-release}"
if security find-identity -p codesigning 2>/dev/null | grep -q '"Keyless Local Dev"'; then
  default_identity="Keyless Local Dev"
else
  default_identity="-"
fi
identity="${KEYLESS_SIGN_IDENTITY:-$default_identity}"
# The hardened runtime enforces library validation: bundled dylibs must share the app's Team ID.
# Ad-hoc and self-signed identities have no Team ID, so local builds sign without it. A Developer ID
# build (needed for notarization) gets the hardened runtime back.
runtime=()
case "$identity" in
  "-" | "Keyless Local Dev") ;;
  *) runtime=(--options runtime) ;;
esac
fermion="$repo/spike/.venv/bin/fermion"
app="$repo/build/Keyless.app"

swift build --package-path "$repo" -c "$config" --product Keyless
bin="$(swift build --package-path "$repo" -c "$config" --show-bin-path)/Keyless"

sherpa="$repo/vendor/sherpa-onnx"
if [ ! -f "$sherpa/lib/libsherpa-onnx-c-api.dylib" ]; then
  echo "sherpa-onnx is missing; run scripts/fetch-sherpa.sh first" >&2
  exit 1
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin" "$app/Contents/MacOS/Keyless"
# Speaker verification: sherpa-onnx + ONNX Runtime, and the 3D-Speaker ERES2Net model.
cp "$sherpa/lib/libsherpa-onnx-c-api.dylib" "$sherpa/lib/libonnxruntime.dylib" "$app/Contents/Frameworks/"
cp "$sherpa/models/3dspeaker-eres2net-en.onnx" "$app/Contents/Resources/"
cp "$sherpa/LICENSE" "$app/Contents/Resources/sherpa-onnx-LICENSE.txt"
for lib in "$app"/Contents/Frameworks/*.dylib; do
  codesign --force --sign "$identity" ${runtime[@]+"${runtime[@]}"} "$lib"
done
# Warm-up clip: synthetic speech from the Milestone 0 fixtures.
cp "$repo/spike/fixtures/audio/short.wav" "$app/Contents/Resources/warmup.wav"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>ai.keyless.Keyless</string>
  <key>CFBundleName</key><string>Keyless</string>
  <key>CFBundleExecutable</key><string>Keyless</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Keyless listens for your voice commands and dictation. Speech is transcribed locally by Phonon-2.</string>
  <key>KeylessFermionPath</key><string>$fermion</string>
</dict>
</plist>
PLIST

codesign --force --sign "$identity" ${runtime[@]+"${runtime[@]}"} \
  --entitlements /dev/stdin "$app" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENT

echo "built $app (signed with ${identity})"
