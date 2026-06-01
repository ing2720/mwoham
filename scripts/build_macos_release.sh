#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/mac-client/MwohamMac/MwohamMac.xcodeproj"
SCHEME="MwohamMac"
CONFIGURATION="Release"
DERIVED_DATA_PATH="/private/tmp/MwohamMacReleaseBuild"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/MwohamMac.app"

echo "Building ${SCHEME} (${CONFIGURATION})..."

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
