#!/bin/bash
# Builds the Windows version on macOS, Linux or Windows (Git Bash). Output: Windows/dist/
#   GifWall.exe + libmpv-2.dll — copy both to the PC and run GifWall.exe (it installs itself).
# Usage: ./build.sh            (needs the .NET 10 SDK: https://dot.net)
set -e
cd "$(dirname "$0")"
DOTNET=$(command -v dotnet || echo "$HOME/.dotnet/dotnet")

# libmpv (video/GIF playback) from the shinchiro/mpv-winbuild-cmake builds, downloaded once.
if [[ ! -f lib/libmpv-2.dll ]]; then
  echo "Downloading libmpv…"
  url=$(curl -fsSL https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest \
        | grep -o 'https://[^"]*mpv-dev-x86_64-[0-9][^"]*\.7z' | head -1)
  mkdir -p lib
  curl -fsSL "$url" -o lib/mpv-dev.7z
  (cd lib && bsdtar -xf mpv-dev.7z libmpv-2.dll 2>/dev/null || 7z e -y mpv-dev.7z libmpv-2.dll >/dev/null)
  rm lib/mpv-dev.7z
fi

rm -rf dist
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$DOTNET" publish GifWall -c Release -o dist
echo "Built Windows/dist (GifWall.exe + libmpv-2.dll)"
