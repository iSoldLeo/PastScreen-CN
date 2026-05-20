#!/usr/bin/env python3
"""Remove PastScreenShortcuts.swift and ScreenshotIntentBridge.swift references from pbxproj v2."""

FILE = "PastScreen-CN.xcodeproj/project.pbxproj"

with open(FILE, "r") as f:
    lines = f.readlines()

patterns = [
    "PastScreen/AppIntents/PastScreenShortcuts.swift",
    "PastScreen/Services/ScreenshotIntentBridge.swift",
    "AppIntents/PastScreenShortcuts.swift",
    "Services/ScreenshotIntentBridge.swift",
]

result = []
for line in lines:
    if any(p in line for p in patterns):
        continue
    result.append(line)

with open(FILE, "w") as f:
    f.writelines(result)

print("Done.")
