#!/usr/bin/env bash
#
# Fast whole-module type check for Mio.
#
# Why this exists
#   Mio builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor (SE-0466). A whole
#   class of isolation error — conformance isolation being the common one — emits
#   ZERO diagnostics unless `-default-isolation MainActor` is passed. A typecheck
#   without that flag reports clean on code that does not build, which is worse
#   than not checking at all. This script guarantees the flag is present.
#
#   It also runs whole-module rather than per-file. Single-file typechecks of this
#   project produce "cannot find type in scope" noise for every cross-file
#   reference, which is not a concurrency finding and trains you to ignore output.
#
# What it is NOT
#   Not a replacement for `xcodebuild`. This does not compile Xcode-generated
#   symbols (asset catalog accessors, string catalog symbols), does not link, and
#   does not package. It catches source-level errors seconds after you save;
#   xcodebuild remains the authoritative verdict before you commit or ship.
#
# Flags are derived from Config/Base.xcconfig at run time, not hardcoded, so that
# changing a build setting cannot silently desync this check from the real build.
#
# Usage
#   scripts/typecheck.sh              # check Mio/
#   scripts/typecheck.sh --quiet      # only print on failure (for hooks)
#   scripts/typecheck.sh path/to/dir  # check a different source root
#
# Exit codes
#   0 = clean · 1 = diagnostics found · 2 = script/environment problem

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

XCCONFIG="Config/Base.xcconfig"
SOURCE_ROOT="Mio"
QUIET=0

for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    -*) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
    *)  SOURCE_ROOT="$arg" ;;
  esac
done

[[ -f "$XCCONFIG"    ]] || { printf 'missing %s (run from the Mio repo)\n' "$XCCONFIG" >&2; exit 2; }
[[ -d "$SOURCE_ROOT" ]] || { printf 'source root not found: %s\n' "$SOURCE_ROOT" >&2; exit 2; }

# Read `KEY = value` out of the xcconfig. Last assignment wins, comments ignored.
xcconfig_value() {
  sed -n -E "s|^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^/]*[^/[:space:]])[[:space:]]*$|\1|p" \
    "$XCCONFIG" | tail -1
}

SWIFT_VERSION="$(xcconfig_value SWIFT_VERSION)"
DEPLOYMENT_TARGET="$(xcconfig_value MACOSX_DEPLOYMENT_TARGET)"
DEFAULT_ISOLATION="$(xcconfig_value SWIFT_DEFAULT_ACTOR_ISOLATION)"
MEMBER_IMPORT_VISIBILITY="$(xcconfig_value SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY)"

[[ -n "$SWIFT_VERSION"     ]] || { printf 'could not read SWIFT_VERSION from %s\n' "$XCCONFIG" >&2; exit 2; }
[[ -n "$DEPLOYMENT_TARGET" ]] || { printf 'could not read MACOSX_DEPLOYMENT_TARGET from %s\n' "$XCCONFIG" >&2; exit 2; }

# swiftc wants `-swift-version 6`, the xcconfig says `6.0`.
SWIFT_MODE="${SWIFT_VERSION%.0}"

# Macro plugins (SwiftUIMacros for @State/#Preview, ObservationMacros for
# @Observable, …) ship only inside a full Xcode.app toolchain — NOT the Command
# Line Tools. If xcode-select points at CommandLineTools, swiftc cannot find
# SwiftUIMacros and every SwiftUI view fails to typecheck. Discover an Xcode.app
# and pin DEVELOPER_DIR so xcrun resolves swiftc + SDK + plugin-server from it.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  current_dev="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$current_dev" != *.app/Contents/Developer ]]; then
    for candidate in \
      /Applications/Xcode.app /Applications/Xcode-beta.app \
      /Applications/Xcode*.app \
      /Volumes/*/Applications/Xcode.app /Volumes/*/Applications/Xcode-beta.app \
      /Volumes/*/Applications/Xcode*.app; do
      if [[ -d "$candidate/Contents/Developer" ]]; then
        export DEVELOPER_DIR="$candidate/Contents/Developer"
        break
      fi
    done
  fi
fi

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)" || { printf 'could not locate the macOS SDK\n' >&2; exit 2; }
TARGET_TRIPLE="$(uname -m)-apple-macos${DEPLOYMENT_TARGET}"

FLAGS=(
  -typecheck
  -swift-version "$SWIFT_MODE"
  -strict-concurrency=complete
  -target "$TARGET_TRIPLE"
  -sdk "$SDK_PATH"
  # swiftc runs each macro plugin under a nested sandbox-exec. In an already
  # sandboxed/restricted shell (CI, agent) `sandbox_apply` fails and the plugin
  # server returns a "malformed response", which surfaces as a bogus
  # "external macro implementation … could not be found". Disabling the plugin
  # sandbox lets first-party Apple macros (SwiftUI/Observation) load. Safe here:
  # the project uses no third-party macros.
  -disable-sandbox
)

# The whole point of the script. Absent this, isolation errors are invisible.
if [[ "$DEFAULT_ISOLATION" == "MainActor" ]]; then
  FLAGS+=(-default-isolation MainActor)
fi

if [[ "$MEMBER_IMPORT_VISIBILITY" == "YES" ]]; then
  FLAGS+=(-enable-upcoming-feature MemberImportVisibility)
fi

# NOTE: SWIFT_APPROACHABLE_CONCURRENCY = YES is deliberately not replicated. It is
# an Xcode meta-setting and the exact set of upcoming-feature flags it expands to
# was not verified, so guessing it would make this baseline diverge from the real
# build in an undocumented direction. Consequence: a diagnostic that only
# approachable-concurrency enables will be caught by xcodebuild, not here.

SOURCES=()
while IFS= read -r -d '' file; do
  SOURCES+=("$file")
done < <(find "$SOURCE_ROOT" -name '*.swift' -type f -print0)

(( ${#SOURCES[@]} > 0 )) || { printf 'no .swift files under %s\n' "$SOURCE_ROOT" >&2; exit 2; }

if (( QUIET == 0 )); then
  printf 'typecheck: %s files under %s/\n' "${#SOURCES[@]}" "$SOURCE_ROOT"
  printf '  swift mode %s · target %s · isolation %s\n' \
    "$SWIFT_MODE" "$TARGET_TRIPLE" "${DEFAULT_ISOLATION:-default}"
fi

OUTPUT="$(xcrun swiftc "${FLAGS[@]}" "${SOURCES[@]}" 2>&1 || true)"
DIAGNOSTICS="$(printf '%s\n' "$OUTPUT" | grep -E '(error|warning):' | sort -u || true)"

if [[ -n "$DIAGNOSTICS" ]]; then
  printf 'typecheck FAILED — %s/ has diagnostics:\n\n' "$SOURCE_ROOT" >&2
  printf '%s\n\n' "$DIAGNOSTICS" >&2
  printf 'Isolation errors? Read .kiro/skills/swift-6-4-guardian/references/conformance-isolation.md\n' >&2
  exit 1
fi

if (( QUIET == 0 )); then
  printf 'typecheck clean. Note: no generated symbols, no link, no packaging —\n'
  printf 'run `xcodebuild -project Mio.xcodeproj -scheme Mio build` before committing.\n'
fi
