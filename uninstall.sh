#!/bin/zsh
# Removes GifWall completely and leaves the system wallpaper as it was before GifWall.
# Usage: ./uninstall.sh
set -u

APP=/Applications/GifWall.app
SUPPORT="$HOME/Library/Application Support/GifWall"
WALLPAPER="$HOME/Library/Application Support/com.apple.wallpaper"
ASSET=6F000000-0000-4000-8000-000000000010

# Quitting normally makes GifWall restore the system wallpaper itself.
if pgrep -x GifWall >/dev/null; then
  echo "Quitting GifWall (restores the wallpaper)…"
  osascript -e 'tell application id "local.gifwall" to quit' 2>/dev/null
  for _ in {1..100}; do pgrep -x GifWall >/dev/null || break; sleep 0.1; done
  pkill -x GifWall 2>/dev/null
fi

# Leftovers from a crash: launching once lets GifWall finish the restore, then it quits.
if [[ -f "$SUPPORT/Index.plist.backup" || -f "$WALLPAPER/aerials/videos/$ASSET.mov" ]] && [[ -d "$APP" ]]; then
  echo "Finishing an interrupted restore…"
  open -g "$APP"
  sleep 4
  osascript -e 'tell application id "local.gifwall" to quit' 2>/dev/null
  for _ in {1..100}; do pgrep -x GifWall >/dev/null || break; sleep 0.1; done
fi

rm -rf "$APP" "$SUPPORT"
defaults delete local.gifwall 2>/dev/null
rm -f "$HOME/Library/Preferences/local.gifwall.plist"
echo "GifWall removed."
