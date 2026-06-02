#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/mac-client/MwohamMac/MwohamMac.xcodeproj"
SCHEME="MwohamMac"
CONFIGURATION="Release"
DERIVED_DATA_PATH="/private/tmp/MwohamMacReleaseBuild"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/MwohamMac.app"

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
xcodebuild -version

rm -rf \
  "${APP_PATH}" \
  "${APP_PATH}.dSYM"

xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "platform=macOS" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Release app not found: ${APP_PATH}" >&2
  exit 1
fi

echo "Release app built:"
echo "${APP_PATH}"
