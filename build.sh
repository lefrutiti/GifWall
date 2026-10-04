#!/bin/zsh
# Builds GifWall.app. Usage: ./build.sh [--install]
set -e
cd "$(dirname "$0")"

# A freshly installed Xcode blocks every tool until its license is accepted; fall back to the Command Line Tools.
if ! xcrun swiftc --version >/dev/null 2>&1 && [[ -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

# swiftc directly: Command Line Tools may ship a broken SwiftPM and SDKs newer than the compiler.
build_with() { swiftc ${=1:+-sdk $1} -O -parse-as-library -target arm64-apple-macosx14.0 Sources/GifWall/*.swift -o .build/GifWall }
mkdir -p .build
if ! build_with "" 2>/dev/null; then
  ok=0
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.*.sdk | sort -rV); do
    if build_with $sdk 2>/tmp/gifwall-build.log; then ok=1; break; fi
  done
  (( ok )) || { cat /tmp/gifwall-build.log; exit 1 }
fi

APP=build/GifWall.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/GifWall $APP/Contents/MacOS/
cp Resources/Info.plist $APP/Contents/
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns $APP/Contents/Resources/
codesign --force --sign - $APP
echo "Built $APP"

if [[ "$1" == "--install" ]]; then
  pkill -x GifWall || true
  rm -rf /Applications/GifWall.app
  cp -R $APP /Applications/
  open /Applications/GifWall.app
  echo "Installed to /Applications"
fi
