# 📸 PastScreen
**Ultra-fast, clipboard-first screenshots for developers on macOS.**

[![Mac App Store](https://img.shields.io/badge/Mac%20App%20Store-Download-blue.svg)](https://apps.apple.com/fr/app/pastscreen/id6755425479?mt=12)
[![Platform](https://img.shields.io/badge/platform-macOS%2014+-lightgrey.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> Capture any region in milliseconds, copy it directly to your clipboard, and keep coding.

---

## 📥 Get PastScreen

### [Download on the Mac App Store](https://apps.apple.com/fr/app/pastscreen/id6755425479?mt=12)
Support the development and get the signed, notarized version with automatic updates directly from Apple.

### Build from Source
PastScreen is open source! If you are a developer, you can build it yourself:

1. Clone the repository:
   ```bash
   git clone https://github.com/augiefra/PastScreen.git
   ```
2. Open the project in Xcode.
3. Build and run (`Cmd + R`) or Archive for Release.

---

## ✨ Highlights
- **Instant clipboard**: Every capture is immediately available as PNG + file path, optimized per app (VSCode/Zed/Cursor, browsers, design tools…).
- **Menu bar native**: Clean macOS menu-bar app with a simple menu, global hotkey (⌥⌘S) and optional Dock icon.
- **Liquid Glass overlay**: Custom selection window with translucent HUD styling and precise dimming.
- **Apple-native notifications**: UN notifications with Finder reveal, silent banners, and a "Saved" pill in the menu bar.
- **Shortcuts & Siri ready**: Capture area/full screen through App Intents, Automation and Spotlight.

---

## 🧩 Tech Stack
- **Swift 5.9**, AppKit + SwiftUI hybrid UI.
- **ScreenCaptureKit** for safe, high-quality captures.
- **TipKit & AppIntents** (macOS 14+)
- Localization: en, fr, es, de, it.

---

## 🔐 Permissions
| Permission | Usage |
|------------|-------|
| Screen Recording | Required for ScreenCaptureKit to read pixels. |
| Accessibility | Needed for the global ⌥⌘S hotkey. |
| Notifications | Banners + Finder reveal after each capture. |

PastScreen never uploads or transmits captures. All operations run locally.

---

## 🛠 Development
- Active work happens on [`PastScreen-dev`](https://github.com/augiefra/PastScreen-dev).
- Public source code mirrors live on [`PastScreen`](https://github.com/augiefra/PastScreen).

---

## 🙌 Credits & License
Built by **(@augiefra)** for developers needing instant, reliable screenshots. Licensed under the [MIT License](LICENSE).

Contributions welcome! File issues, discuss ideas, or propose PRs. Enjoy lightning-fast screenshots. ⚡️