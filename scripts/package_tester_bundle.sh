#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="${ROOT_DIR}/scripts/build_macos_release.sh"
DERIVED_DATA_PATH="/private/tmp/MwohamMacReleaseBuild"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/MwohamMac.app"
DIST_DIR="${ROOT_DIR}/dist"
BUNDLE_DIR="${DIST_DIR}/MwohamMacTesterBundle"
ZIP_PATH="${DIST_DIR}/MwohamMacTesterBundle.zip"

"${BUILD_SCRIPT}"

rm -rf "${BUNDLE_DIR}" "${ZIP_PATH}"
mkdir -p "${BUNDLE_DIR}"

cp -R "${APP_PATH}" "${BUNDLE_DIR}/MwohamMac.app"
cp "${ROOT_DIR}/docs/TESTER_INSTALL_GUIDE.md" "${BUNDLE_DIR}/TESTER_INSTALL_GUIDE.md"
cp "${ROOT_DIR}/docs/QA_CHECKLIST.md" "${BUNDLE_DIR}/QA_CHECKLIST.md"

(
  cd "${DIST_DIR}"
  /usr/bin/zip -qry "$(basename "${ZIP_PATH}")" "$(basename "${BUNDLE_DIR}")"
)

echo "Tester bundle created:"
echo "${BUNDLE_DIR}"
echo "${ZIP_PATH}"
