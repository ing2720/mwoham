#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/mac-client/MwohamMac/MwohamMac.xcodeproj"
SCHEME="MwohamMac"
CONFIGURATION="Debug"
DERIVED_DATA_PATH="${ROOT_DIR}/.derivedData/MwohamMac"
BUILT_APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/MwohamMac.app"
APP_PATH="${APP_PATH:-${HOME}/Applications/MwohamMac.app}"
SHOULD_OPEN=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/build_macos_app.sh [--open] [--destination /path/to/MwohamMac.app]

Builds MwohamMac Debug app into a stable bundle path.
Default destination: ~/Applications/MwohamMac.app
EOF
}

absolute_path() {
  local path="$1"
  if [[ "${path}" = /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s\n' "${ROOT_DIR}/${path}"
  fi
}

validate_app_path() {
  local path="$1"
  local basename
  basename="$(basename "${path}")"

  if [[ -z "${path}" ]]; then
    echo "APP_PATH is empty; refusing to delete." >&2
    exit 1
  fi
  if [[ "${path}" == "/" ]]; then
    echo "APP_PATH points to /; refusing to delete." >&2
    exit 1
  fi
  if [[ "${path}" == "/Applications" ]]; then
    echo "APP_PATH points to /Applications; refusing to delete." >&2
    exit 1
  fi
  if [[ "${path}" == "${HOME}/Applications" ]]; then
    echo "APP_PATH points to ~/Applications; refusing to delete." >&2
    exit 1
  fi
  if [[ "${path}" != *.app ]]; then
    echo "APP_PATH must end with .app: ${path}" >&2
    exit 1
  fi
  if [[ "${basename}" != "MwohamMac.app" ]]; then
    echo "APP_PATH basename must be MwohamMac.app: ${path}" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --open)
      SHOULD_OPEN=1
      shift
      ;;
    --destination)
      if [[ $# -lt 2 ]]; then
        echo "--destination requires a path." >&2
        exit 1
      fi
      APP_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

APP_PATH="$(absolute_path "${APP_PATH}")"
validate_app_path "${APP_PATH}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install full Xcode and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "${DEVELOPER_DIR}" != *"/Xcode.app/Contents/Developer" ]]; then
  echo "Full Xcode is required to build MwohamMac.app." >&2
  echo "Current developer directory: ${DEVELOPER_DIR:-not configured}" >&2
  echo "Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "Xcode project not found: ${PROJECT_PATH}" >&2
  echo "Run this script from the repository root or check that mac-client/MwohamMac exists." >&2
  exit 1
fi

echo "Building ${SCHEME} (${CONFIGURATION})..."
echo "DerivedData: ${DERIVED_DATA_PATH}"
xcodebuild -version

xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "platform=macOS" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build

if [[ ! -d "${BUILT_APP_PATH}" ]]; then
  echo "Built app not found: ${BUILT_APP_PATH}" >&2
  exit 1
fi

echo "Stopping running MwohamMac process if present..."
pkill -x MwohamMac 2>/dev/null || true

echo "Replacing app bundle..."
echo "From: ${BUILT_APP_PATH}"
echo "To:   ${APP_PATH}"
mkdir -p "$(dirname "${APP_PATH}")"
rm -rf "${APP_PATH}"
ditto "${BUILT_APP_PATH}" "${APP_PATH}"

echo "App bundle ready:"
echo "${APP_PATH}"

if [[ "${SHOULD_OPEN}" -eq 1 ]]; then
  echo "Opening app..."
  open "${APP_PATH}"
fi
