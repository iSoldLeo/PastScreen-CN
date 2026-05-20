#!/usr/bin/env python3
"""
Reverse orphan scanner: find references to symbols that no longer exist.
"""
import os, subprocess

PROJECT_ROOT = "/Users/isold/Documents/软件项目/PastScreen-CN"
PASTSCREEN_DIR = os.path.join(PROJECT_ROOT, "PastScreen")

# All symbols deleted in this session
DELETED_SYMBOLS = [
    # CaptureLibraryView.swift
    "CaptureLibraryWindow", "CaptureLibraryManager", "CaptureLibraryViewModel",
    "CaptureLibraryRootView", "CaptureLibraryView", "CaptureLibraryQuickLookCoordinator",
    # PastScreenShortcuts.swift
    "CaptureShortcutReturnType", "CaptureAreaIntent", "CaptureFullScreenIntent",
    "CaptureAdvancedAreaIntent", "CaptureOCRIntent", "CaptureWindowIntent", "PastScreenShortcuts",
    # ScreenshotIntentBridge.swift
    "ScreenshotIntentBridge", "AutomationReturnType", "IntentError",
    "triggerAreaCapture", "triggerFullScreenCapture", "captureArea", "captureFullScreen",
    "captureAdvancedArea", "captureOCR", "captureWindow",
    # PastScreenApp.swift deleted
    "performAreaCaptureForAutomation", "performAdvancedAreaCaptureForAutomation",
    "performOCRCaptureForAutomation", "performFullScreenCaptureForAutomation",
    "performWindowCaptureForAutomation",
    # ScreenshotService.swift deleted
    "AutomationRequest", "automationRequest", "beginAutomationRequest",
    "postAutomationResult", "completeAutomationIfNeeded", "writeAutomationFileAndPost",
    "writeAutomationFile",
    # SettingsView.swift deleted
    "TrailingSwitchToggleStyle",
    # Notifications deleted
    "automationCaptureCompleted",
]

def find_refs(sym):
    cmd = [
        "grep", "-rn",
        r"\b" + sym + r"\b",
        PASTSCREEN_DIR,
        "--include=*.swift"
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
        return result.stdout.strip()
    except Exception as e:
        return f"ERROR: {e}"

print("=== Reverse Orphan Scan (references to deleted symbols) ===\n")
found = []
for sym in DELETED_SYMBOLS:
    refs = find_refs(sym)
    if refs:
        found.append((sym, refs))

if not found:
    print("No reverse orphans found. All deleted symbols are fully cleaned up.")
else:
    print(f"Found {len(found)} symbols with remaining references:\n")
    for sym, refs in found:
        print(f"--- {sym} ---")
        print(refs)
        print()
