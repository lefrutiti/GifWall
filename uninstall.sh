#!/bin/zsh
# Removes GifWall completely: its wallpapers disappear from System Settings and the wallpaper from before
# GifWall comes back. Usage: ./uninstall.sh
set -u

APP=/Applications/GifWall.app
SUPPORT="$HOME/Library/Application Support/GifWall"

if [[ -d "$APP" ]]; then
  # GifWall cleans up after itself when its bundle disappears while it runs (see UninstallWatcher).
  pgrep -x GifWall >/dev/null || { open -g "$APP"; sleep 3; }
  echo "Removing GifWall and its wallpapers from System Settings…"
  mv "$APP" "$HOME/.Trash/GifWall-$(date +%s).app"
  for _ in {1..150}; do pgrep -x GifWall >/dev/null || break; sleep 0.1; done
  rm -rf "$HOME"/.Trash/GifWall-*.app
fi

if pgrep -x GifWall >/dev/null; then
  echo "GifWall didn't finish cleaning up; quit it and run this script again." >&2
  exit 1
fi

rm -rf "$SUPPORT"
defaults delete local.gifwall 2>/dev/null
rm -f "$HOME/Library/Preferences/local.gifwall.plist"
echo "GifWall removed."
