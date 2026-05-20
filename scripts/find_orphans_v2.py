#!/usr/bin/env python3
"""
 orphan scanner v2: stricter heuristics, lower false-positive rate.
 Only reports symbols with ZERO cross-file usage and filters common FP patterns.
"""
import os, re
from collections import defaultdict

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASTSCREEN_DIR = os.path.join(PROJECT_ROOT, "PastScreen")

def find_swift_files(root):
    for dirpath, _, filenames in os.walk(root):
        for f in filenames:
            if f.endswith(".swift"):
                yield os.path.join(dirpath, f)

# Capture: private|fileprivate (static)? func|var|let|class|struct|enum NAME
DECL_RE = re.compile(
    r'^\s*(?:private|fileprivate)\s+(?:static\s+)?(?:func|var|let|class|struct|enum)\s+(\w+)'
)

# Secondary pattern: static before access level
DECL_RE2 = re.compile(
    r'^\s*static\s+(?:private|fileprivate)\s+(?:func|var|let)\s+(\w+)'
)

SKIP_SYMBOLS = {
    'init', 'deinit', 'body', 'preview', 'makeBody', 'makeNSView', 'updateNSView',
    'makeUIView', 'updateUIView', 'makeCoordinator', 'makeWindow',
}

# Swift constructs that are used by the framework, not explicit call
SKIP_KEYWORDS = ['override', '@objc', '@IBAction', '@IBOutlet', 'preview', '@main']

def is_skip_line(line):
    kw = [k for k in SKIP_KEYWORDS if k in line]
    return bool(kw)

def count_references(sym, exclude_decl_files):
    """Count usages across all files, excluding declarations."""
    total = 0
    files = set()
    pat = re.compile(r'(?<!\.)\b' + re.escape(sym) + r'\b')
    for filepath in find_swift_files(PASTSCREEN_DIR):
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        for m in pat.finditer(content):
            line_start = content.rfind('\n', 0, m.start()) + 1
            line_end = content.find('\n', m.start())
            line = content[line_start:line_end if line_end != -1 else len(content)]
            # Skip declaration lines
            if DECL_RE.search(line) or DECL_RE2.search(line):
                continue
            total += 1
            files.add(filepath)
    return total, files

def main():
    decls = []  # (filepath, line_no, line_text, sym)
    for filepath in find_swift_files(PASTSCREEN_DIR):
        with open(filepath, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        for i, line in enumerate(lines, 1):
            if is_skip_line(line):
                continue
            m = DECL_RE.match(line) or DECL_RE2.match(line)
            if m:
                sym = m.group(1)
                if sym in SKIP_SYMBOLS:
                    continue
                decls.append((filepath, i, line.strip(), sym))

    print(f"=== High-confidence orphan scan (0 usages outside declaration) ===\n")
    candidates = []
    for filepath, line_no, line_text, sym in decls:
        total, files = count_references(sym, set())
        if total == 0:
            rel = filepath.replace(PROJECT_ROOT + '/', '')
            candidates.append((rel, line_no, line_text, sym))

    print(f"Found {len(candidates)} zero-usage candidates:\n")
    for rel, line_no, line_text, sym in candidates:
        print(f"{rel}:{line_no}: {line_text}")

    # Also save to file for review
    out = os.path.join(PROJECT_ROOT, "scripts", "orphan_candidates.txt")
    with open(out, 'w') as f:
        for rel, line_no, line_text, sym in candidates:
            f.write(f"{rel}:{line_no}: {line_text}\n")
    print(f"\nSaved to {out}")

if __name__ == '__main__':
    main()
