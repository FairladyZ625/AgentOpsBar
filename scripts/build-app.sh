#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -P "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="AgentOpsBar"
EXEC_NAME="AgentOpsBar"
OUT_DIR="${ROOT_DIR}/dist"
SIGN_IDENTITY=""
FORCE_ADHOC=0
DO_INSTALL=0
DO_OPEN=0

usage() {
  cat <<'EOF'
Usage: scripts/build-app.sh [options]

Build and code-sign AgentOpsBar.app (macOS menu bar & floating HUD monitor).

Options:
  --identity <name|sha1>  Explicit codesign identity (default: auto-detect Developer ID -> Apple Development -> ad-hoc)
  --adhoc                 Sign ad-hoc (-) without querying Keychain certificates
  --out-dir <dir>         Output directory for .app bundle (default: ./dist)
  --install               Copy built .app into /Applications (fallback ~/Applications)
  --open                  Launch (or restart) the built/installed .app when done
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      SIGN_IDENTITY="${2:?missing value for --identity}"
      shift 2
      ;;
    --adhoc)
      FORCE_ADHOC=1
      shift
      ;;
    --out-dir)
      OUT_DIR="${2:?missing value for --out-dir}"
      shift 2
      ;;
    --install)
      DO_INSTALL=1
      shift
      ;;
    --open)
      DO_OPEN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "build-app.sh: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

echo "[1/4] Compiling ${EXEC_NAME} (release)..."
swift build -c release --package-path "${ROOT_DIR}"
BIN_DIR="$(swift build -c release --package-path "${ROOT_DIR}" --show-bin-path)"
BUILT_BIN="${BIN_DIR}/${EXEC_NAME}"

if [[ ! -x "${BUILT_BIN}" ]]; then
  echo "build-app.sh: release binary not found at ${BUILT_BIN}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
APP_BUNDLE="${OUT_DIR}/${APP_NAME}.app"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

echo "[2/4] Bundling resources, AppIcon.icns & Info.plist..."
ICONSET_TMP="$(mktemp -d "${TMPDIR:-/tmp}/agentopsbar-icon.XXXXXX")"
ICONSET_DIR="${ICONSET_TMP}/AppIcon.iconset"
trap 'rm -rf "${ICONSET_TMP}"' EXIT
swift "${SCRIPT_DIR}/generate_icon.swift" "${ICONSET_DIR}"
iconutil -c icns "${ICONSET_DIR}" -o "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

cp "${BUILT_BIN}" "${APP_BUNDLE}/Contents/MacOS/${EXEC_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${EXEC_NAME}"

cp "${ROOT_DIR}/Resources/agent_ops_probe.py" "${APP_BUNDLE}/Contents/Resources/agent_ops_probe.py"
chmod +x "${APP_BUNDLE}/Contents/Resources/agent_ops_probe.py"
cp "${ROOT_DIR}/packaging/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

detect_identity() {
  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  local dev_id
  dev_id="$(printf '%s\n' "${identities}" | awk -F'"' '/Developer ID Application:/ {print $2; exit}')"
  if [[ -n "${dev_id}" ]]; then
    printf '%s' "${dev_id}"
    return 0
  fi
  local apple_dev
  apple_dev="$(printf '%s\n' "${identities}" | awk -F'"' '/Apple Development:/ {print $2; exit}')"
  if [[ -n "${apple_dev}" ]]; then
    printf '%s' "${apple_dev}"
    return 0
  fi
  printf '%s' "-"
}

if [[ "${FORCE_ADHOC}" -eq 1 ]]; then
  RESOLVED_IDENTITY="-"
elif [[ -n "${SIGN_IDENTITY}" ]]; then
  RESOLVED_IDENTITY="${SIGN_IDENTITY}"
else
  RESOLVED_IDENTITY="$(detect_identity)"
fi

echo "[3/4] Code-signing with identity: ${RESOLVED_IDENTITY}"
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true
if [[ "${RESOLVED_IDENTITY}" == "-" ]]; then
  codesign --force --deep --sign - "${APP_BUNDLE}"
else
  if ! codesign --force --deep --options runtime --timestamp --sign "${RESOLVED_IDENTITY}" "${APP_BUNDLE}"; then
    echo "  Timestamp server unreachable; retrying local Developer signature without RFC3161 timestamp..."
    codesign --force --deep --options runtime --timestamp=none --sign "${RESOLVED_IDENTITY}" "${APP_BUNDLE}"
  fi
fi
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

FINAL_APP="${APP_BUNDLE}"
if [[ "${DO_INSTALL}" -eq 1 ]]; then
  if [[ -w "/Applications" ]]; then
    INSTALL_ROOT="/Applications"
  else
    INSTALL_ROOT="${HOME}/Applications"
    mkdir -p "${INSTALL_ROOT}"
  fi
  FINAL_APP="${INSTALL_ROOT}/${APP_NAME}.app"
  echo "[4/4] Installing to ${FINAL_APP}..."
  pkill -x "${EXEC_NAME}" 2>/dev/null || true
  sleep 0.2
  rm -rf "${FINAL_APP}"
  ditto "${APP_BUNDLE}" "${FINAL_APP}"
else
  echo "[4/4] Bundle ready at ${FINAL_APP}"
fi

if [[ "${DO_OPEN}" -eq 1 ]]; then
  pkill -x "${EXEC_NAME}" 2>/dev/null || true
  sleep 0.2
  open "${FINAL_APP}"
  echo "Launched ${FINAL_APP}"
fi
