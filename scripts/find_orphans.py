#!/usr/bin/env python3
"""
 orphan scanner: finds likely-unused private/fileprivate symbols across Swift files.
 Heuristic-based; not a substitute for compiler dead-code analysis.
"""
import os, re, sys
from collections import defaultdict

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASTSCREEN_DIR = os.path.join(PROJECT_ROOT, "PastScreen")

def find_swift_files(root):
    for dirpath, _, filenames in os.walk(root):
        for f in filenames:
            if f.endswith(".swift"):
                yield os.path.join(dirpath, f)

# Patterns for declarations we care about
DECL_PATTERNS = [
    # private/fileprivate func/var/let/class/struct/enum
    re.compile(r'^\s*(?:private|fileprivate)\s+(?:func|var|let|class|struct|enum)\s+(\w+)'),
    # static private/fileprivate
    re.compile(r'^\s*(?:private|fileprivate)\s+static\s+(?:func|var|let)\s+(\w+)'),
    re.compile(r'^\s*static\s+(?:private|fileprivate)\s+(?:func|var|let)\s+(\w+)'),
]

# Patterns for usages (rough)
def find_symbol_in_text(text, symbol):
    # Match the symbol as a whole word, but not when it looks like a declaration
    pattern = re.compile(r'(?<!\.)\b' + re.escape(symbol) + r'\b')
    matches = []
    for m in pattern.finditer(text):
        # Check if this match is part of a declaration line
        line_start = text.rfind('\n', 0, m.start()) + 1
        line_end = text.find('\n', m.start())
        if line_end == -1:
            line_end = len(text)
        line = text[line_start:line_end]
        # Skip if line contains declaration keywords before the symbol
        decl_prefix = re.search(r'(?:private|fileprivate|internal|public|open|static)\s+(?:func|var|let|class|struct|enum)', line[:m.start()-line_start])
        if decl_prefix and m.start() - line_start < 60:
            continue
        matches.append(m)
    return matches

def main():
    symbols = defaultdict(list)  # symbol -> [(filepath, is_decl, line)]

    for filepath in find_swift_files(PASTSCREEN_DIR):
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()

        for line_no, line in enumerate(content.split('\n'), 1):
            for pat in DECL_PATTERNS:
                m = pat.match(line)
                if m:
                    sym = m.group(1)
                    # Skip common non-orphans
                    if sym in ('init', 'deinit', 'body', 'preview', 'makeBody', 'makeNSView', 'updateNSView'):
                        continue
                    symbols[sym].append((filepath, True, line_no, line.strip()))
                    break

    # Now count usages across ALL swift files for each declared symbol
    all_files = list(find_swift_files(PASTSCREEN_DIR))

    results = []
    for sym, decls in symbols.items():
        total_refs = 0
        decl_count = len(decls)
        ref_details = []

        for filepath in all_files:
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()

            matches = find_symbol_in_text(content, sym)
            if matches:
                total_refs += len(matches)
                ref_details.append(filepath)

        # Heuristic: if total references == decl_count, likely unused
        # (each declaration line itself might be matched as a "ref" by our pattern,
        #  but we try to filter those out in find_symbol_in_text)
        # More robust: if total_refs <= decl_count
        if total_refs <= decl_count:
            results.append((sym, decls, total_refs, ref_details))

    # Sort by file then line
    results.sort(key=lambda x: (x[1][0][0], x[1][0][2]))

    print(f"=== Likely orphan private/fileprivate symbols ( heuristic, verify before deleting ) ===\n")
    print(f"Found {len(results)} candidates\n")

    for sym, decls, total_refs, ref_details in results:
        for filepath, is_decl, line_no, line_text in decls:
            rel = filepath.replace(PROJECT_ROOT + '/', '')
            print(f"{rel}:{line_no}: {line_text}")
            print(f"  -> total usages found: {total_refs} (in {len(ref_details)} file(s))")
            if ref_details:
                print(f"  -> files: {', '.join(os.path.basename(p) for p in ref_details)}")
            print()

if __name__ == '__main__':
    main()
