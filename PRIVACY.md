# Privacy Policy for PastScreen

**Last Updated:** November 24, 2025

## Overview

PastScreen is a privacy-first screenshot application for macOS. We take your privacy seriously and have designed the app to operate entirely on your device with zero data collection.

## Data Collection

**PastScreen collects NO personal data whatsoever.**

- No user accounts or authentication required
- No analytics or tracking
- No crash reports sent to external servers
- No telemetry or usage statistics
- No cloud storage or uploads
- No network connections (except for Sparkle auto-updates in the direct distribution version)

## Local Processing Only

All screenshot processing happens locally on your Mac:

- Screenshots are captured using macOS Screen Capture APIs
- Images are saved to your local disk in a user-selected folder
- Clipboard operations use standard macOS pasteboard APIs
- All settings are stored locally in macOS UserDefaults

**Your screenshots never leave your device.**

## Required Permissions

PastScreen requires the following macOS system permissions to function:

### 1. Screen Recording
- **Purpose:** Required to capture screenshots of your screen
- **Usage:** Only activated when you trigger a screenshot capture
- **Scope:** Limited to the screen regions you explicitly select

### 2. Accessibility
- **Purpose:** Required to register global keyboard shortcuts
- **Usage:** Listens for your configured hotkey (default: ⌥⌘S)
- **Scope:** Limited to keyboard event monitoring for registered shortcuts only

### 3. Notifications (Optional)
- **Purpose:** Display confirmation notifications after screenshots
- **Usage:** Shows native macOS notifications with "Reveal in Finder" action
- **Scope:** Limited to screenshot capture confirmations

**PastScreen only uses these permissions for their stated purposes and does not access any other system resources.**

## Screen Recording Data - Detailed Disclosure

This section provides comprehensive information about how PastScreen uses the Screen Recording permission, in compliance with Apple App Store guidelines.

### What Features Use Screen Recording

PastScreen uses screen recording for **ONE purpose only**: screenshot capture. When you trigger a capture:
1. A selection overlay appears on your screen
2. You select a rectangular region by clicking and dragging
3. The app captures ONLY that selected region as a static image
4. The image is saved locally and/or copied to your clipboard

**No background recording. No continuous capture. No video recording.**

### What Data Is Collected Via Screen Recording

When you take a screenshot, PastScreen captures:
- **Static image data**: A single PNG or JPG image of your selected screen region

PastScreen does NOT collect:
- No metadata embedded in images (no timestamps, no location, no device IDs)
- No text extraction or OCR
- No image analysis or content scanning
- No facial recognition
- No object detection

### Purpose of Screen Recording Data

The captured screenshot data is used SOLELY for:
- Saving the image to your local disk (user-selected folder)
- Copying the image to your clipboard for pasting into other applications

**There is no other use.** PastScreen is a simple utility that captures and saves screenshots at your explicit request.

### Third-Party Sharing

**NO screenshot data is shared with any third party:**
- No cloud uploads
- No network transmission of images
- No analytics services receive image data
- No advertising networks
- No external APIs are called with your screenshots

**All screenshot data remains 100% local on your device.**

### Data Storage Location

Your screenshots are stored in TWO places only, both on your local device:
- **Local disk**: In a folder you explicitly select via the standard macOS folder picker (accessible in Finder)
- **System clipboard**: Temporarily, for paste operations into other applications

**No cloud storage. No external servers. No remote databases.**

### Data Retention

- Screenshots remain on your disk until YOU manually delete them
- Clipboard data is replaced when you copy something else
- PastScreen does not automatically delete your screenshots (unless you use a custom cleanup setting)
- You have full control over your screenshot files at all times

## Data Storage

Screenshots are stored locally on your Mac:

- **Default location:** `~/Pictures/Screenshots/`
- **Configurable:** You can change the save location in app preferences
- **Retention:** Files remain until you manually delete them
- **Cleanup option:** Optional "Clear on Restart" feature to automatically delete screenshots on app launch

## Third-Party Services

PastScreen does not use any third-party analytics, tracking, or data collection services. All functionality is self-contained within the app.

## Open Source

PastScreen is open source software:
- **Repository:** https://github.com/augiefra/PastScreen
- **License:** Check repository for license details
- **Transparency:** All source code is publicly auditable
- **Community:** Anyone can review, contribute, or verify privacy claims

## Children's Privacy

PastScreen does not collect any data from anyone, including children under 13. The app is rated 4+ and contains no objectionable content.

## Changes to This Policy

We may update this Privacy Policy from time to time. Changes will be reflected in the "Last Updated" date at the top of this document and published in the GitHub repository.

## Contact

For privacy-related questions or concerns:
- **GitHub Issues:** https://github.com/augiefra/PastScreen/issues
- **Repository:** https://github.com/augiefra/PastScreen

## Your Rights

Since PastScreen collects no personal data:
- There is no data to access, modify, or delete on our end
- All your data remains on your device under your control
- You can delete the app and all its screenshots at any time
- No data remains on external servers (because none was ever sent)

---

**Summary:** PastScreen is designed with privacy as a core principle. Your screenshots, settings, and usage patterns remain entirely on your device. We don't collect, transmit, or store any of your personal information.
