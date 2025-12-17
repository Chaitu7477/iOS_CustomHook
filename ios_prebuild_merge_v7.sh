#!/bin/sh
set -eu

PROP_XCODEPROJ="${1-}"
ENV_XCODEPROJ="${2-}"
PROP_WORKSPACE="${3-}"
ENV_WORKSPACE="${4-}"

log() { printf '[hook] %s
' "$*"; }

choose_path() {
  a="$1"; b="$2"; name="$3"; out=""
  case "$a" in *'${'*|'') ;; *) out="$a" ;; esac
  if [ -z "$out" ]; then
    case "$b" in *'${'*|'') ;; *) out="$b" ;; esac
  fi
  if [ -z "$out" ]; then log "WARN: $name not provided"; else log "Using $name = $out"; fi
  printf '%s' "$out"
}

WORKSPACE_PATH="$(choose_path "$PROP_WORKSPACE" "$ENV_WORKSPACE" PROJECT_VMWORKSPACE_PATH)"
XCODEPROJ_RAW="$(choose_path "$PROP_XCODEPROJ" "$ENV_XCODEPROJ" PROJECT_XCODEPROJECT)"

resolve_against_workspace() {
  candidate="$1"
  case "$candidate" in /*) printf '%s' "$candidate" ;; *)
    base="${WORKSPACE_PATH:-$(pwd)}"
    printf '%s/%s' "$base" "$candidate" ;;
  esac
}

XCODEPROJ_BUNDLE=""
PBXPROJ=""

if [ -n "$XCODEPROJ_RAW" ]; then
  case "$XCODEPROJ_RAW" in
    *.xcodeproj/project.pbxproj)
      PBXPROJ="$(resolve_against_workspace "$XCODEPROJ_RAW")"
      XCODEPROJ_BUNDLE="$(dirname "$PBXPROJ")"
      ;;
    *.xcodeproj)
      XCODEPROJ_BUNDLE="$(resolve_against_workspace "$XCODEPROJ_RAW")"
      PBXPROJ="$XCODEPROJ_BUNDLE/project.pbxproj"
      ;;
    *)
      maybe="$(resolve_against_workspace "$XCODEPROJ_RAW")"
      if [ -d "$maybe" ]; then
        XCODEPROJ_BUNDLE="$(find "$maybe" -type d -name "*.xcodeproj" | head -n 1)"
        if [ -n "$XCODEPROJ_BUNDLE" ]; then PBXPROJ="$XCODEPROJ_BUNDLE/project.pbxproj"; fi
      elif [ -f "$maybe" ]; then
        case "$maybe" in */project.pbxproj)
          PBXPROJ="$maybe"; XCODEPROJ_BUNDLE="$(dirname "$maybe")" ;;
        esac
      fi
      ;;
  esac
fi

if [ -z "$PBXPROJ" ] || [ ! -f "$PBXPROJ" ]; then
  if [ -z "$WORKSPACE_PATH" ] || [ ! -d "$WORKSPACE_PATH" ]; then
    log "ERROR: workspace/project paths not available; ensure hook is configured at iOS IPA_STAGE"
    exit 3
  fi
  XCODEPROJ_BUNDLE="$(find "$WORKSPACE_PATH" -type d -name "*.xcodeproj" | head -n 1)"
  if [ -z "$XCODEPROJ_BUNDLE" ]; then
    XCODEPROJ_BUNDLE="$(find "$WORKSPACE_PATH" -type d -path "*Native*" -name "*.xcodeproj" | head -n 1)"
  fi
  if [ -z "$XCODEPROJ_BUNDLE" ]; then
    log "ERROR: .xcodeproj not found in workspace"
    exit 4
  fi
  PBXPROJ="$XCODEPROJ_BUNDLE/project.pbxproj"
fi

if [ ! -f "$PBXPROJ" ]; then
  log "ERROR: pbxproj not found: $PBXPROJ"
  exit 5
fi

log "Resolved Xcode bundle: $XCODEPROJ_BUNDLE"
log "pbxproj: $PBXPROJ"

# Compute base root once to avoid nested quotes/backticks
BASE_ROOT="${WORKSPACE_PATH:-$(dirname "$XCODEPROJ_BUNDLE")}"

# Req-1: Resolve SPM packages
log "Resolving Swift packages via xcodebuild…"
if ! xcodebuild -project "$XCODEPROJ_BUNDLE" -resolvePackageDependencies -quiet ; then
  log "ERROR: xcodebuild failed to resolve packages. Ensure CLI tools and a valid scheme exist."
  exit 20
fi
log "SPM dependencies resolved."

# Req-2: Replace AppDelegateExtension
log "Replacing AppDelegateExtension under VMAppWithKonylib…"
SRC_EXT_DIR="$(pwd)/AppDelegateExtension_Files"
if [ ! -d "$SRC_EXT_DIR" ]; then
  log "ERROR: AppDelegateExtension_Files missing in hook zip"
  exit 30
fi
VMKONY_DIR="$(find "$BASE_ROOT" -type d -name "VMAppWithKonylib" | head -n 1)"
if [ -z "$VMKONY_DIR" ]; then VMKONY_DIR="$(dirname "$XCODEPROJ_BUNDLE")"; fi
DEST_EXT_DIR="$VMKONY_DIR/AppDelegateExtension"
mkdir -p "$DEST_EXT_DIR"
rm -rf "$DEST_EXT_DIR"/*
# copy all including hidden files
( cd "$SRC_EXT_DIR" && tar -cf - . ) | ( cd "$DEST_EXT_DIR" && tar -xf - )
log "AppDelegateExtension replaced at $DEST_EXT_DIR"

# Req-3: Cleanup duplicate Certificates
log "Cleaning duplicate 'Certificates' under NLResources…"
NL_RES_DIRS_OUTPUT="$(find "$BASE_ROOT" -type d -name "NLResources" || true)"
if [ -n "$NL_RES_DIRS_OUTPUT" ]; then
  echo "$NL_RES_DIRS_OUTPUT" | while IFS= read -r nl; do
    CERTS_OUTPUT="$(find "$nl" -type d -name "Certificates" | tr '
' '
')"
    FIRST_CERT="$(echo "$CERTS_OUTPUT" | head -n 1)"
    OTHERS_CERTS="$(echo "$CERTS_OUTPUT" | tail -n +2)"
    if [ -n "$OTHERS_CERTS" ]; then
      echo "$OTHERS_CERTS" | while IFS= read -r c; do
        [ -n "$c" ] && { log "Deleting duplicate: $c"; rm -rf "$c"; }
      done
      log "Removed duplicates in $nl"
    fi
  done
else
  log "Note: NLResources not found; skipping."
fi

log "IPA_STAGE tasks completed successfully."
