
#!/bin/bash

set -eu

# ---------------------------
# Inputs via positional args
# ---------------------------
PROP_XCODEPROJ_BUNDLE="${1-}"
ENV_XCODEPROJ_BUNDLE="${2-}"
PROP_WORKSPACE="${3-}"
ENV_WORKSPACE="${4-}"

# ---------------------------
# Logging helper
# ---------------------------
log() { printf '[hook] %s\n' "$*"; }

# ---------------------------
# Choose path: prefer explicit values over unresolved tokens
# ---------------------------
choose_path() {
  local a="$1" b="$2" name="$3" out=""
  case "$a" in *'${'* ) ;; * ) out="$a" ;; esac
  if [ -z "$out" ]; then
    case "$b" in *'${'* ) ;; * ) out="$b" ;; esac
  fi
  if [ -z "$out" ]; then log "WARN: $name not provided"; else log "Using $name = $out"; fi
  printf '%s' "$out"
}

# ---------------------------
# Basic pre-check: xcodebuild
# ---------------------------
if ! command -v xcodebuild >/dev/null 2>&1; then
  log "ERROR: xcodebuild not found; ensure Xcode is installed on the macOS agent"
  exit 6
fi

# ---------------------------
# Normalize workspace
# ---------------------------
ENV_WORKSPACE="${ENV_WORKSPACE:-${WORKSPACE:-}}"
WORKSPACE_PATH="$(choose_path "$PROP_WORKSPACE" "$ENV_WORKSPACE" PROJECT_VMWORKSPACE_PATH)"
if [ -z "$WORKSPACE_PATH" ]; then
  # Fall back to Jenkins WORKSPACE or current directory
  WORKSPACE_PATH="${WORKSPACE:-$(pwd)}"
fi

# ---------------------------
# Resolve project path (.xcodeproj / pbxproj)
# ---------------------------
XCODE_RAW="$(choose_path "$PROP_XCODEPROJ_BUNDLE" "$ENV_XCODEPROJ_BUNDLE" PROJECT_XCODEPROJECT)"
resolve_against_workspace() {
  local candidate="$1"
  case "$candidate" in
    /*) printf '%s' "$candidate" ;;
    *)  printf '%s/%s' "${WORKSPACE_PATH:-$(pwd)}" "$candidate" ;;
  esac
}

XCODEPROJ_DIR=""
PBXPROJ=""

if [ -n "$XCODE_RAW" ]; then
  case "$XCODE_RAW" in
    *.xcodeproj/project.pbxproj)
      PBXPROJ="$(resolve_against_workspace "$XCODE_RAW")"
      XCODEPROJ_DIR="$(dirname "$PBXPROJ")"
      ;;
    *.xcodeproj)
      XCODEPROJ_DIR="$(resolve_against_workspace "$XCODE_RAW")"
      PBXPROJ="$XCODEPROJ_DIR/project.pbxproj"
      ;;
    *)
      maybe="$(resolve_against_workspace "$XCODE_RAW")"
      if [ -d "$maybe" ]; then
        XCODEPROJ_DIR="$(find "$maybe" -type d -name "*.xcodeproj" | head -n 1 || true)"
        if [ -n "$XCODEPROJ_DIR" ]; then PBXPROJ="$XCODEPROJ_DIR/project.pbxproj"; fi
      elif [ -f "$maybe" ] && [[ "$maybe" == */project.pbxproj ]]; then
        PBXPROJ="$maybe"; XCODEPROJ_DIR="$(dirname "$maybe")"
      fi
      ;;
  esac
fi

# If not resolved yet, try workspace-driven discovery
if [ -z "$PBXPROJ" ] || [ ! -f "$PBXPROJ" ]; then
  if [ -z "$WORKSPACE_PATH" ] || [ ! -d "$WORKSPACE_PATH" ]; then
    log "ERROR: workspace/project paths not available; ensure hook is configured at iOS IPA_STAGE"
    exit 3
  fi

  # First try direct .xcodeproj discovery
  XCODEPROJ_DIR="$(find "$WORKSPACE_PATH" -type d -name "*.xcodeproj" | head -n 1 || true)"
  # If your projects often live under "Native" paths, add a secondary scan
  if [ -z "$XCODEPROJ_DIR" ]; then
    XCODEPROJ_DIR="$(find "$WORKSPACE_PATH" -type d -path "*Native*" -name "*.xcodeproj" | head -n 1 || true)"
  fi

  if [ -z "$XCODEPROJ_DIR" ]; then
    log "ERROR: .xcodeproj not found in workspace"
    exit 4
  fi
  PBXPROJ="$XCODEPROJ_DIR/project.pbxproj"
fi

if [ ! -f "$PBXPROJ" ]; then
  log "ERROR: pbxproj not found: $PBXPROJ"
  exit 5
fi

log "Resolved Xcode bundle: $XCODEPROJ_DIR"
log "pbxproj: $PBXPROJ"

# ---------------------------
# Target (adjust if needed)
# ---------------------------
TARGET_NAME="${TARGET_NAME:-KRelease}"  # default to KRelease as per your current script
log "Using target: $TARGET_NAME"

# ---------------------------
# Add package dependencies by URL
# ---------------------------
log "Adding Branch SDK (SPM)"
if ! xcodebuild \
      -project "$XCODEPROJ_DIR" \
      -addPackageDependency "https://github.com/BranchMetrics/ios-branch-deep-linking-attribution" \
      -target "$TARGET_NAME"; then
  log "ERROR: Failed to add Branch SDK package"
  exit 7
fi

log "Adding XtremePush SDK (SPM)"
if ! xcodebuild \
      -project "$XCODEPROJ_DIR" \
      -addPackageDependency "https://github.com/xtremepush/XtremePush-iOS-SDK" \
      -target "$TARGET_NAME"; then
  log "ERROR: Failed to add XtremePush SDK package"
  exit 7
fi

# ---------------------------
# Force update to latest compatible versions
# (remove Package.resolved, clear DerivedData, resolve again)
# ---------------------------

# 1) Remove Package.resolved (prevents reuse of old pins)
pkgResolvedPaths="$(find "$(dirname "$XCODEPROJ_DIR")" -path "*/xcshareddata/swiftpm/Package.resolved" || true)"
if [ -n "$pkgResolvedPaths" ]; then
  log "Removing Package.resolved to refetch latest pins"
  # shellcheck disable=SC2001
  echo "$pkgResolvedPaths" | while read -r p; do
    [ -n "$p" ] && rm -f "$p"
  done
fi

# 2) Clear DerivedData (Xcode caches SPM checkouts here)
DERIVED="$(xcodebuild -project "$XCODEPROJ_DIR" -showBuildSettings \
  | grep -m1 BUILD_DIR | grep -oE "/.*" | sed 's|/Build/Products||' || true)"
if [ -n "$DERIVED" ] && [ -d "$DERIVED" ]; then
  log "Clearing DerivedData: $DERIVED"
  rm -rf "$DERIVED"
fi

# 3) Re-resolve packages (fetch latest versions permitted by rules)
log "Resolving Swift Packages to latest allowed versions"
if ! xcodebuild -project "$XCODEPROJ_DIR" -resolvePackageDependencies; then
  log "ERROR: Failed to resolve Swift package dependencies"
  exit 8
fi

log "=== iOS IPA_STAGE SPM Hook completed successfully ==="
``
