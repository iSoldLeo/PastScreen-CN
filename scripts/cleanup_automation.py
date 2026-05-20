#!/usr/bin/env python3
"""
Remove all automation-related code from ScreenshotService.swift.
Handles: if-blocks, single-line calls, and dangling braces.
"""
import re

FILE = "PastScreen/Services/ScreenshotService.swift"

with open(FILE, "r") as f:
    lines = f.readlines()

result = []
skip_depth = 0

for line in lines:
    stripped = line.strip()

    # Start skipping if we hit an automationRequest if-block with {
    if re.search(r"if\s+.*automationRequest.*\{", stripped):
        skip_depth = line.count("{") - line.count("}")
        continue

    # Also skip: let pendingAutomation = automationRequest
    if "let pendingAutomation = automationRequest" in stripped:
        skip_depth = line.count("{") - line.count("}")
        continue

    # Also skip: if pendingAutomation != nil { automationRequest = nil }
    if re.search(r"if\s+pendingAutomation\s*!=\s*nil", stripped):
        skip_depth = line.count("{") - line.count("}")
        continue

    # Also skip: if let pendingAutomation {
    if re.search(r"if\s+let\s+pendingAutomation\s*\{", stripped):
        skip_depth = line.count("{") - line.count("}")
        continue

    if skip_depth > 0:
        skip_depth += line.count("{") - line.count("}")
        if skip_depth <= 0:
            skip_depth = 0
        continue

    # Delete single-line calls (not function declarations)
    if any(call in stripped for call in [
        "completeAutomationIfNeeded(",
        "writeAutomationFileAndPost(",
        "postAutomationResult("
    ]):
        if not any(decl in stripped for decl in [
            "func completeAutomationIfNeeded",
            "func writeAutomationFileAndPost",
            "func postAutomationResult"
        ]):
            continue

    result.append(line)

with open(FILE, "w") as f:
    f.writelines(result)

print("Done.")
