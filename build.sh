#!/bin/zsh
# Builds HyprMac.app. Pass --install to copy it into ~/Applications and launch it.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
APP=build/HyprMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HyprMac "$APP/Contents/MacOS/HyprMac"

# App icon: render the tiled apple and pack it into an .icns.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift Tools/make-icon.swift build/icon.png >/dev/null
for px in 16 32 128 256 512; do
    sips -z $px $px build/icon.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) build/icon.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>HyprMac</string>
    <key>CFBundleDisplayName</key><string>HyprMac</string>
    <key>CFBundleIdentifier</key><string>dev.hyprmac.HyprMac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>HyprMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.2-beta</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with a stable self-signed certificate. Ad-hoc signatures change on every
# build, which makes macOS silently invalidate the Accessibility permission.
# The certificate lives in its own keychain file (not your login keychain, and
# not marked as trusted), created once on the first build.
SIGN_DIR=~/.config/hyprmac/signing
KEYCHAIN=$SIGN_DIR/hyprmac-signing.keychain-db
IDENTITY="HyprMac Local Signing"
if [[ ! -f $KEYCHAIN ]]; then
    echo "Creating local signing certificate in $KEYCHAIN"
    mkdir -p $SIGN_DIR && chmod 700 $SIGN_DIR
    TMP=$(mktemp -d)
    cat > $TMP/cfg <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$IDENTITY
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
    openssl req -x509 -newkey rsa:2048 -nodes -keyout $TMP/key.pem -out $TMP/cert.pem -days 3650 -config $TMP/cfg 2>/dev/null
    openssl pkcs12 -export -inkey $TMP/key.pem -in $TMP/cert.pem -out $TMP/id.p12 -passout pass:hyprmac -name "$IDENTITY"
    SEARCH=("${(@f)$(security list-keychains -d user | tr -d ' "')}")
    security create-keychain -p hyprmac $KEYCHAIN
    security list-keychains -d user -s "${SEARCH[@]}"   # keep it out of the search list
    security unlock-keychain -p hyprmac $KEYCHAIN
    security import $TMP/id.p12 -k $KEYCHAIN -P hyprmac -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k hyprmac $KEYCHAIN >/dev/null 2>&1
    rm -rf $TMP
fi
security unlock-keychain -p hyprmac $KEYCHAIN
codesign --force --keychain $KEYCHAIN --sign "$IDENTITY" "$APP"
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x HyprMac 2>/dev/null && sleep 1 || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/HyprMac.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/HyprMac.app
    echo "Installed to ~/Applications/HyprMac.app and launched."
fi
