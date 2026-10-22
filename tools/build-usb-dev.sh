#!/bin/zsh
# Standalone sender build with Command Line Tools; no Xcode/SPM download needed.
set -euo pipefail
cd "${0:A:h:h}"
APP="build/Build/Products/Debug/OpenDisplay Dev.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/Dev.iconset
SOURCES=(Mac/*.swift Shared/*.swift)
SOURCES=(${SOURCES:#Mac/CheckForUpdatesView.swift})
swiftc -O -g -D DEBUG -swift-version 5 -target arm64-apple-macos14.0 \
  -module-name OpenSidecarMac \
  -import-objc-header Mac/OpenSidecarMac-Bridging-Header.h \
  "${SOURCES[@]}" -o "$APP/Contents/MacOS/OpenDisplay Dev"
python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
info = {
    'CFBundleIdentifier': 'com.peetzweg.opensidecar.mac.debug',
    'CFBundleName': 'OpenDisplay Dev', 'CFBundleDisplayName': 'OpenDisplay Dev',
    'CFBundleExecutable': 'OpenDisplay Dev', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.25.0-usb.1', 'CFBundleVersion': '1',
    'CFBundleIconFile': 'AppIcon', 'LSMinimumSystemVersion': '14.0',
    'NSPrincipalClass': 'NSApplication', 'LSUIElement': True,
    'NSLocalNetworkUsageDescription': '连接同一局域网的 OpenDisplay 接收端。',
    'NSBonjourServices': ['_opensidecar._tcp'],
}
with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info, f)
for size in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        source = pathlib.Path(f'Mac/Assets.xcassets/AppIcon-Dev.appiconset/icon_{size*scale}.png')
        name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
        (pathlib.Path('build/Dev.iconset')/name).write_bytes(source.read_bytes())
PY
iconutil -c icns build/Dev.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
codesign --force --sign - \
  --requirements '=designated => identifier "com.peetzweg.opensidecar.mac.debug"' \
  --entitlements Mac/OpenSidecarMac.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP — launch with ./run.sh"
