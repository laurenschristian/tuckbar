#!/bin/sh
# ./build.sh            build build/TuckBar.app (universal)
# ./build.sh install    build, copy to /Applications, launch
# ./build.sh release    build and package build/TuckBar-v<version>.dmg
set -e
cd "$(dirname "$0")"
APP=build/TuckBar.app
BIN="$APP/Contents/MacOS/TuckBar"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
for arch in arm64 x86_64; do
  swiftc -O -whole-module-optimization -target "$arch-apple-macos13.0" Sources/*.swift -o "build/TuckBar-$arch"
done
lipo -create build/TuckBar-arm64 build/TuckBar-x86_64 -output "$BIN"
rm build/TuckBar-arm64 build/TuckBar-x86_64
# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc signing resets it every build.
SIGN_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${SIGN_ID:--}" "$APP"

case "$1" in
  install)
    pkill -x TuckBar || true
    rm -rf /Applications/TuckBar.app
    cp -R "$APP" /Applications/
    open /Applications/TuckBar.app
    ;;
  release)
    STAGE=build/dmg
    rm -rf "$STAGE" "build/TuckBar-v$VERSION.dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname TuckBar -srcfolder "$STAGE" -ov -format UDZO "build/TuckBar-v$VERSION.dmg"
    rm -rf "$STAGE"
    shasum -a 256 "build/TuckBar-v$VERSION.dmg"
    ;;
esac
