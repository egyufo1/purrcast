#!/bin/zsh
# Builds "Purrcast.app" into ./build. Usage: ./build_app.sh [--install]  (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")"

Resources/Localization/check.sh
swift build -c release --product Purrcast
APP="build/Purrcast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Purrcast" "$APP/Contents/MacOS/Purrcast"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Icon/purr.svg Resources/Fonts/*.ttf Resources/Fonts/OFL-Geist.txt "$APP/Contents/Resources/"
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
# CFBundleLocalizations = every bundled language, so macOS offers all of them.
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleLocalizations" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$PLIST"
for dir in Resources/Localization/*.lproj; do
    /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string $(basename "$dir" .lproj)" "$PLIST"
done
# FFmpeg (LGPL, see scripts/build_ffmpeg.sh): executables next to the app binary, libraries in Frameworks.
[[ -x vendor/ffmpeg/bin/ffmpeg ]] || scripts/build_ffmpeg.sh
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
cp vendor/ffmpeg/bin/ffmpeg vendor/ffmpeg/bin/ffprobe "$APP/Contents/MacOS/"
for lib in vendor/ffmpeg/lib/lib*.dylib; do
    # Only the names the binaries link against (@rpath/libavcodec.62.dylib …), as real files.
    [[ "$(basename "$lib")" =~ '^lib[a-z]+\.[0-9]+\.dylib$' ]] && cp -L "$lib" "$APP/Contents/Frameworks/"
done
cp vendor/ffmpeg/licenses/* "$APP/Contents/Resources/Licenses/"
cp Resources/Fonts/OFL-Geist.txt "$APP/Contents/Resources/Licenses/"

# Sign from the inside out.
codesign --force --sign - "$APP"/Contents/Frameworks/*.dylib "$APP/Contents/MacOS/ffmpeg" "$APP/Contents/MacOS/ffprobe"
codesign --force --sign - "$APP"
echo "Kész: $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Purrcast.app"
    # The app was called "AirPlay Player" before; its settings are taken over on the first launch.
    rm -rf "/Applications/AirPlay Player.app"
    cp -R "$APP" /Applications/
    echo "Telepítve: /Applications/Purrcast.app"
fi
