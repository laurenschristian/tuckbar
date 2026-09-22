<p align="center">
  <img src="icon.png" width="128" height="128" alt="TuckBar icon">
</p>

<h1 align="center">TuckBar</h1>

<p align="center">
  A lightweight, native menu bar organizer for macOS.
</p>

<p align="center">
  <a href="https://github.com/laurenschristian/tuckbar/releases/latest"><img src="https://img.shields.io/github/v/release/laurenschristian/tuckbar" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
  <img src="https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-lightgrey" alt="Universal binary">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/laurenschristian/tuckbar" alt="MIT License"></a>
</p>

## Overview

TuckBar hides menu bar icons you do not need to see all the time. Click one control to show or hide them.

TuckBar is built for low, stable resource use. It is a single AppKit source file with no dependencies, timers, polling, or network access. It draws its icons once at launch. After that, it does no work until you click it.

## Performance

Measured on macOS 26, Apple Silicon:

| Metric | TuckBar 1.0.0 |
| --- | --- |
| Memory footprint | 25 MB, stable over time |
| Idle CPU | 0% |
| App bundle size | 420 KB |
| Download size | 252 KB |

## Features

- Show or hide menu bar icons with one click
- Optional auto-hide 10 seconds after you expand
- Launch at login
- Positions persist across restarts
- Universal binary for Apple Silicon and Intel
- No analytics, no network access, no settings window

## Requirements

- macOS 13 Ventura or later

## Installation

### Homebrew (recommended)

```sh
brew install --cask laurenschristian/tap/tuckbar
xattr -dr com.apple.quarantine /Applications/TuckBar.app
```

### Manual download

1. Download the latest `TuckBar-vX.Y.Z.dmg` from [Releases](https://github.com/laurenschristian/tuckbar/releases/latest).
2. Open the disk image and drag TuckBar to Applications.
3. Run `xattr -dr com.apple.quarantine /Applications/TuckBar.app`.

> [!NOTE]
> TuckBar is not notarized by Apple yet, so Gatekeeper blocks the first launch. The `xattr` command removes the download quarantine flag. You can also approve the app in System Settings > Privacy & Security > Open Anyway.

## Usage

1. Launch TuckBar. A chevron and a `|` separator appear in the menu bar.
2. Hold Cmd and drag the icons you want to hide to the left of the separator.
3. Click the chevron to show or hide those icons.
4. Right-click or Option-click the chevron to open the menu.

| Menu item | Description |
| --- | --- |
| Auto-hide after 10s | Hides the icons again 10 seconds after you expand them |
| Launch at Login | Starts TuckBar when you log in |
| Quit TuckBar | Quits the app |

The chevron must stay to the right of the separator. If the order is reversed, TuckBar does not collapse, so it cannot hide its own control.

## How it works

TuckBar adds two status items: a chevron and a separator. To hide icons, it expands the separator to 10,000 points wide. This pushes every item to its left off screen. To show them, it returns the separator to its normal width. macOS stores each item's position, so the layout persists across restarts.

## Building from source

Building requires the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/laurenschristian/tuckbar.git
cd tuckbar
./build.sh install
```

| Command | Result |
| --- | --- |
| `./build.sh` | Builds `build/TuckBar.app` (universal) |
| `./build.sh install` | Builds, installs to `/Applications`, and launches |
| `./build.sh release` | Builds `build/TuckBar-v<version>.dmg` and prints its SHA-256 |
| `swift scripts/make-icon.swift` | Regenerates `icon.png` and `Resources/AppIcon.icns` |

The version is set in `Info.plist`.

## Uninstalling

```sh
brew uninstall --zap --cask tuckbar
```

For a manual install, quit TuckBar, delete `/Applications/TuckBar.app`, and run `defaults delete com.laurenschristian.tuckbar`.

## License

TuckBar is released under the [MIT License](LICENSE).
