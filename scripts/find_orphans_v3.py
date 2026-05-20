#!/usr/bin/env python3
"""
 orphan scanner v3: handles self./Self. usage correctly.
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

# Capture declarations
DECL_PATTERNS = [
    re.compile(r'^\s*(?:private|fileprivate)\s+(?:static\s+)?(?:func|var|let|class|struct|enum)\s+(\w+)'),
    re.compile(r'^\s*static\s+(?:private|fileprivate)\s+(?:func|var|let)\s+(\w+)'),
]

SKIP_SYMBOLS = {
    'init', 'deinit', 'body', 'preview', 'makeBody', 'makeNSView', 'updateNSView',
    'makeUIView', 'updateUIView', 'makeCoordinator',
}

SKIP_KEYWORDS = ['override', '@objc', '@IBAction', '@IBOutlet', '@main']

def is_skip_line(line):
    return any(k in line for k in SKIP_KEYWORDS)

def is_declaration_line(line):
    for pat in DECL_PATTERNS:
        if pat.search(line):
            return True
    return False

def count_refs(sym):
    total = 0
    files = set()
    pat = re.compile(r'\b' + re.escape(sym) + r'\b')
    for filepath in find_swift_files(PASTSCREEN_DIR):
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        for m in pat.finditer(content):
            line_start = content.rfind('\n', 0, m.start()) + 1
            line_end = content.find('\n', m.start())
            line = content[line_start:line_end if line_end != -1 else len(content)]
            if is_declaration_line(line):
                continue
            total += 1
            files.add(filepath)
    return total, files

def main():
    decls = []
    for filepath in find_swift_files(PASTSCREEN_DIR):
        with open(filepath, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        for i, line in enumerate(lines, 1):
            if is_skip_line(line):
                continue
            for pat in DECL_PATTERNS:
                m = pat.match(line)
                if m:
                    sym = m.group(1)
                    if sym in SKIP_SYMBOLS:
                        break
                    decls.append((filepath, i, line.strip(), sym))
                    break

    print(f"=== Orphan scan v3 (0 usages outside declaration) ===\n")
    candidates = []
    for filepath, line_no, line_text, sym in decls:
        total, files = count_refs(sym)
        if total == 0:
            rel = filepath.replace(PROJECT_ROOT + '/', '')
            candidates.append((rel, line_no, line_text, sym))

    print(f"Found {len(candidates)} zero-usage candidates:\n")
    for rel, line_no, line_text, sym in candidates:
        print(f"{rel}:{line_no}: {line_text}")

    out = os.path.join(PROJECT_ROOT, "scripts", "orphan_candidates_v3.txt")
    with open(out, 'w') as f:
        for rel, line_no, line_text, sym in candidates:
            f.write(f"{rel}:{line_no}: {line_text}\n")
    print(f"\nSaved to {out}")

if __name__ == '__main__':
    main()
