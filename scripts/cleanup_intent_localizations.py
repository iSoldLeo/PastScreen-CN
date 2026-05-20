#!/usr/bin/env python3
"""Remove all intent.* localization keys from .strings files."""
import os
import re

PASTSCREEN_DIR = "PastScreen"

for dirpath, _, filenames in os.walk(PASTSCREEN_DIR):
    for f in filenames:
        if f.endswith(".strings"):
            filepath = os.path.join(dirpath, f)
            with open(filepath, "r", encoding="utf-8") as file:
                lines = file.readlines()

            result = []
            for line in lines:
                if re.match(r'"intent\.', line.strip()):
                    continue
                result.append(line)

            with open(filepath, "w", encoding="utf-8") as file:
                file.writelines(result)

print("Done.")
