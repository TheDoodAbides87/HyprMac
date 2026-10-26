#!/bin/zsh
# Builds HyprMac.app.
#   --install  copy it into ~/Applications and launch it
#   --dmg      also package it as build/HyprMac-<version>.dmg for sharing
set -euo pipefail
cd "${0:A:h}"

VERSION=${HYPRMAC_VERSION:-1.1.0}
INSTALL=0
DMG=0
for arg in "$@"; do
    case $arg in
        --install) INSTALL=1 ;;
        --dmg) DMG=1 ;;
        *) echo "Unknown option: $arg (use --install and/or --dmg)" >&2; exit 2 ;;
    esac
done

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
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
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

if (( INSTALL )); then
    pkill -x HyprMac 2>/dev/null && sleep 1 || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/HyprMac.app
    cp -R "$APP" ~/Applications/
    # Launch Services sometimes drops a launch right after the old copy quits,
    # even when `open` reports success, so check it's running and retry.
    for attempt in 1 2 3; do
        open ~/Applications/HyprMac.app 2>/dev/null
        sleep 3
        pgrep -x HyprMac >/dev/null && break
        echo "HyprMac didn't start; retrying ($attempt/3)…"
    done
    pgrep -x HyprMac >/dev/null || { echo "Couldn't launch HyprMac; open it from ~/Applications." >&2; exit 1; }
    echo "Installed to ~/Applications/HyprMac.app and launched."
fi

if (( DMG )); then
    # A disk image with the app, a shortcut to Applications and a background
    # that says to drag one onto the other: the usual Mac installer.
    VOL=HyprMac
    OUT="build/HyprMac-$VERSION.dmg"
    STAGE=build/dmg
    RW=build/dmg-rw.dmg
    rm -rf "$STAGE" "$RW" "$OUT"
    mkdir -p "$STAGE/.background"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    swift Tools/make-dmg-background.swift build/dmg-bg.png 1
    swift Tools/make-dmg-background.swift build/dmg-bg@2x.png 2
    tiffutil -cathidpicheck build/dmg-bg.png build/dmg-bg@2x.png -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

    [[ -d /Volumes/$VOL ]] && { hdiutil detach "/Volumes/$VOL" -quiet || hdiutil detach "/Volumes/$VOL" -force -quiet; }
    hdiutil create -quiet -ov -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW "$RW"
    MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')

    # Lay out the window. This asks Finder, which macOS may ask you to allow once;
    # without it the disk image still works, just with Finder's default layout.
    if ! osascript >/dev/null <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "HyprMac.app" of container window to {165, 190}
        set position of item "Applications" of container window to {495, 190}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    then
        echo "Note: couldn't arrange the installer window (Finder automation not allowed); the disk image still works."
    fi

    sync
    # Disk icon. Added last: Finder deletes it while saving the window layout.
    cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT"

    sync
    hdiutil detach "$MOUNT" -quiet || { sleep 2; hdiutil detach "$MOUNT" -force -quiet; }
    hdiutil convert "$RW" -quiet -format UDZO -imagekey zlib-level=9 -o "$OUT"
    rm -rf "$RW" "$STAGE"
    codesign --force --keychain $KEYCHAIN --sign "$IDENTITY" "$OUT"
    echo "Built $PWD/$OUT"
fi
