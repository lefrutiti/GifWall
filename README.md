# GifWall

Live wallpapers for macOS: videos and animated GIFs on the desktop and the lock screen.

GifWall lives in the menu bar. Drop in a video, GIF or ZIP and it becomes a wallpaper in
**System Settings → Wallpaper**, next to Apple's own, where you can switch between all the ones you've added.
The lock screen and screen saver play it natively; GifWall draws the animated desktop.

## Features

- **Formats:** MP4, MOV, M4V (H.264, HEVC, ProRes), GIF, WebP, APNG, HEICS, and ZIP archives of these
  (including Wallpaper Engine projects of type *video*).
- **Library in System Settings:** every added file is its own entry in a "GifWall" section; pick one there or in the
  menu bar panel.
- **Light on resources:** files are converted once to hardware-decoded HEVC, sized to your largest display and capped
  at 30 fps. Playback pauses while the desktop is covered, the screen sleeps, or you switch user.
- **Leaves no trace:** removing the app (Trash or `uninstall.sh`) removes its wallpapers from System Settings and puts back
  the wallpaper you had before.

## Requirements

- macOS 14 Sonoma or later, Apple silicon.
- Animated lock screen: macOS 26. Earlier versions show a still frame there.
- To build: Xcode or the Command Line Tools (`xcode-select --install`). No other dependencies.

## Install

```sh
git clone https://github.com/lefrutiti/GifWall.git
cd GifWall
./build.sh --install    # builds GifWall.app, copies it to /Applications and launches it
```

The app is ad-hoc signed, so macOS may say it can't verify the developer the first time. Open it with
right-click → **Open**, or allow it in **System Settings → Privacy & Security**.

`./build.sh` alone builds `build/GifWall.app` without installing.

## Use

1. Click the menu bar icon and drag a file onto the panel (or **Add…**, or *Open With → GifWall* in Finder).
2. The file is converted and selected. To switch, use the panel or **System Settings → Wallpaper → GifWall**.
3. Right-click a wallpaper in the panel to rename or delete it.

The switch at the top turns the animated desktop on and off. **Launch at login** keeps it running after a restart.
When GifWall isn't running the desktop shows a still frame; the lock screen still animates.

## Uninstall

Move GifWall to the Trash while it's running, or run:

```sh
./uninstall.sh
```

Either way, its wallpapers disappear from System Settings and your previous wallpaper comes back.

## How it works

macOS only animates its own Aerial wallpapers. GifWall registers each video as an Aerial in the user's wallpaper
manifest (`~/Library/Application Support/com.apple.wallpaper`) and points the wallpaper store at it. This is undocumented
and may break with a macOS update.

The lock screen player needs HEVC with temporal layers, like Apple's Aerials, or it freezes after the first unlock;
videos are encoded with VideoToolbox accordingly (see `LayeredHEVCWriter.swift`).

## Windows

`Windows/` has a separate tray app for Windows 10/11 that plays the wallpaper on the desktop with libmpv. It has a
single wallpaper rather than a library. Build it with the .NET 10 SDK:

```sh
cd Windows && ./build.sh    # output: Windows/dist/GifWall.exe + libmpv-2.dll
```

## License

[MIT](LICENSE)
