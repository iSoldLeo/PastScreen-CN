# 📸 PastScreen

**Ultra-fast, clipboard-first screenshots for developers on macOS.**

[![Mac App Store](https://img.shields.io/badge/Mac%20App%20Store-Download-blue.svg)](https://apps.apple.com/fr/app/pastscreen/id6755425479?mt=12)
[![Platform](https://img.shields.io/badge/platform-macOS%2014+-lightgrey.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> Capture any region in milliseconds, copy it directly to your clipboard, and keep coding.

---

## 📥 Get PastScreen

### 🍎 [Download on the Mac App Store](https://apps.apple.com/fr/app/pastscreen/id6755425479?mt=12)

The easiest way! Get the signed, notarized version with automatic updates directly from Apple.

**Support the development** — if you find PastScreen useful, the App Store version helps keep the project alive.

### 🛠 Build from Source

PastScreen is **100% open source**! If you prefer to build it yourself:

```bash
git clone https://github.com/augiefra/PastScreen.git
cd PastScreen
open PastScreen.xcodeproj
```

Then build and run (`Cmd + R`) or Archive for Release.

---

## 🆕 What's New in v2.2

### Simplified Clipboard Behavior
- **Default**: Screenshots are copied as **image only** to the clipboard
- Works reliably with AI agents (Zed AI, ChatGPT, Claude), browsers, and all apps
- No more inconsistent paste results!

### App-Specific Overrides
- Go to **Settings > Apps** to customize clipboard format per application
- Set an app to **"Path"** mode if you need the file path instead (useful for terminals)

### UI Improvements
- Larger Settings window with better scrolling
- Cleaner, simplified Apps settings tab

---

## ✨ Highlights

- **Instant clipboard**: Every capture is immediately copied as an image, ready to paste anywhere.
- **Smart app overrides**: Force "Path" mode for terminals, "Image" mode for everything else.
- **Menu bar native**: Clean macOS menu-bar app with global hotkey (⌥⌘S) and optional Dock icon.
- **Liquid Glass overlay**: Custom selection window with translucent HUD styling.
- **Apple-native notifications**: Banners with Finder reveal after each capture.
- **Shortcuts & Siri ready**: Capture via App Intents, Automation and Spotlight.

---

## 🧩 Tech Stack

- **Swift 5.9**, AppKit + SwiftUI hybrid UI
- **ScreenCaptureKit** for safe, high-quality captures
- **TipKit & AppIntents** (macOS 14+)
- Localization: 🇬🇧 en, 🇫🇷 fr, 🇪🇸 es, 🇩🇪 de, 🇮🇹 it

---

## 🔐 Permissions

| Permission | Usage |
|------------|-------|
| Screen Recording | Required for ScreenCaptureKit to capture pixels |
| Accessibility | Needed for the global ⌥⌘S hotkey |
| Notifications | Banners + Finder reveal after each capture |

**Privacy**: PastScreen never uploads or transmits captures. All operations run locally.

---

## 🛠 Development

- Active development: [`PastScreen-dev`](https://github.com/augiefra/PastScreen-dev)
- Public releases: [`PastScreen`](https://github.com/augiefra/PastScreen)

---

## 🙌 Credits & License

Built by **@augiefra** for developers who need instant, reliable screenshots.

Licensed under the [MIT License](LICENSE) — free to use, modify, and distribute.

Contributions welcome! File issues, discuss ideas, or open PRs.

Enjoy lightning-fast screenshots! ⚡️