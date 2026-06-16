#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="${ROOT_DIR}/mac-client/MwohamMac/MwohamMac.xcodeproj/project.pbxproj"
BUILD_SCRIPT="${ROOT_DIR}/scripts/build_macos_app.sh"
MACOS_WORKFLOW="${ROOT_DIR}/.github/workflows/macos.yml"

expect_count() {
  local expected="$1"
  local pattern="$2"
  local file="$3"
  local actual
  actual="$(grep -F -c "${pattern}" "${file}" || true)"
  if [[ "${actual}" -ne "${expected}" ]]; then
    echo "failed: expected ${expected} occurrences of '${pattern}', got ${actual}" >&2
    exit 1
  fi
}

expect_count 2 \
  "PRODUCT_BUNDLE_IDENTIFIER = com.ing2720.MwohamMac;" \
  "${PROJECT_FILE}"
expect_count 2 "CODE_SIGN_STYLE = Automatic;" "${PROJECT_FILE}"
expect_count 2 "CODE_SIGN_IDENTITY = \"Apple Development\";" "${PROJECT_FILE}"
expect_count 2 \
  "DEVELOPMENT_TEAM = \"\$(MWOHAM_DEVELOPMENT_TEAM)\";" \
  "${PROJECT_FILE}"
expect_count 2 "INFOPLIST_KEY_CFBundleDisplayName = MwohamMac;" \
  "${PROJECT_FILE}"
expect_count 0 \
  "\"CODE_SIGN_IDENTITY[sdk=macosx*]\" = \"Apple Development\";" \
  "${PROJECT_FILE}"

grep -Fq 'APP_PATH="${APP_PATH:-${HOME}/Applications/MwohamMac.app}"' \
  "${BUILD_SCRIPT}"
grep -Fq 'EXPECTED_BUNDLE_IDENTIFIER="com.ing2720.MwohamMac"' \
  "${BUILD_SCRIPT}"
grep -Fq 'EXPECTED_DISPLAY_NAME="MwohamMac"' "${BUILD_SCRIPT}"
grep -Fq 'codesign --verify --deep --strict' "${BUILD_SCRIPT}"
grep -Fq 'LaunchServices.framework/Support/lsregister' "${BUILD_SCRIPT}"
grep -Fq 'open -n "${APP_PATH}"' "${BUILD_SCRIPT}"
grep -Fq 'The build stopped without falling back to unsigned mode.' \
  "${BUILD_SCRIPT}"
grep -Fq 'CODE_SIGNING_ALLOWED=NO' "${MACOS_WORKFLOW}"

bash -n "${BUILD_SCRIPT}"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT
SIGNING_CONFIG="${TEMP_DIR}/missing-signing.env"
IDENTITY='Apple Development: dlguddns2@naver.com (4TU7GC9X3Z)'
IDENTITIES="  1) ABCDEF1234567890 \"${IDENTITY}\""

run_preflight() {
  MWOHAM_SIGNING_CONFIG="${SIGNING_CONFIG}" \
  MWOHAM_BUILD_PREFLIGHT_ONLY=1 \
  "$@"
}

if run_preflight "${BUILD_SCRIPT}" >"${TEMP_DIR}/missing-team.log" 2>&1; then
  echo "failed: signed mode must reject a missing Team ID" >&2
  exit 1
fi
grep -Fq "MWOHAM_DEVELOPMENT_TEAM is required" \
  "${TEMP_DIR}/missing-team.log"
grep -Fq "Available code signing identities:" \
  "${TEMP_DIR}/missing-team.log"
grep -Fq "Resolved build settings:" "${TEMP_DIR}/missing-team.log"

MWOHAM_DEVELOPMENT_TEAM=4TU7GC9X3Z \
MWOHAM_SECURITY_IDENTITIES="${IDENTITIES}" \
MWOHAM_CERTIFICATE_TEAM_ID=4TU7GC9X3Z \
run_preflight "${BUILD_SCRIPT}" >"${TEMP_DIR}/signed.log" 2>&1
grep -Fq "Build mode: signed" "${TEMP_DIR}/signed.log"
grep -Fq "Configuration: Debug" "${TEMP_DIR}/signed.log"
grep -Fq "Team ID: 4TU7GC9X3Z" "${TEMP_DIR}/signed.log"
grep -Fq "Resolved signing identity: ${IDENTITY}" "${TEMP_DIR}/signed.log"
grep -Fq "Resolved signing identity fingerprint: ABCDEF1234567890" \
  "${TEMP_DIR}/signed.log"
grep -Fq "Resolved signing style: Manual" "${TEMP_DIR}/signed.log"
grep -Fq "App output path: ${HOME}/Applications/MwohamMac.app" \
  "${TEMP_DIR}/signed.log"

MWOHAM_DEVELOPMENT_TEAM=4TU7GC9X3Z \
MWOHAM_SECURITY_IDENTITIES="${IDENTITIES}" \
MWOHAM_CERTIFICATE_TEAM_ID=4TU7GC9X3Z \
run_preflight "${BUILD_SCRIPT}" --release \
  >"${TEMP_DIR}/signed-release.log" 2>&1
grep -Fq "Build mode: signed" "${TEMP_DIR}/signed-release.log"
grep -Fq "Configuration: Release" "${TEMP_DIR}/signed-release.log"
grep -Fq "signed Release" "${TEMP_DIR}/signed-release.log"

MWOHAM_DEVELOPMENT_TEAM=4TU7GC9X3Z \
MWOHAM_CODE_SIGN_IDENTITY="${IDENTITY}" \
MWOHAM_SECURITY_IDENTITIES="${IDENTITIES}" \
MWOHAM_CERTIFICATE_TEAM_ID=4TU7GC9X3Z \
run_preflight "${BUILD_SCRIPT}" >"${TEMP_DIR}/exact-identity.log" 2>&1
grep -Fq "Resolved signing identity: ${IDENTITY}" \
  "${TEMP_DIR}/exact-identity.log"

if MWOHAM_DEVELOPMENT_TEAM=4TU7GC9X3Z \
  MWOHAM_SECURITY_IDENTITIES='0 valid identities found' \
  run_preflight "${BUILD_SCRIPT}" >"${TEMP_DIR}/missing-identity.log" 2>&1; then
  echo "failed: signed mode must reject a missing identity" >&2
  exit 1
fi
grep -Fq "Apple Development identity not found" \
  "${TEMP_DIR}/missing-identity.log"
grep -Fq "Available code signing identities:" \
  "${TEMP_DIR}/missing-identity.log"

run_preflight "${BUILD_SCRIPT}" --unsigned \
  >"${TEMP_DIR}/unsigned.log" 2>&1
grep -Fq "Build mode: unsigned" "${TEMP_DIR}/unsigned.log"
grep -Fq "Team ID: none" "${TEMP_DIR}/unsigned.log"
grep -Fq "Resolved signing style: none" "${TEMP_DIR}/unsigned.log"
grep -Fq "unsigned/ad-hoc build입니다." "${TEMP_DIR}/unsigned.log"

run_preflight "${BUILD_SCRIPT}" --unsigned --release \
  >"${TEMP_DIR}/unsigned-release.log" 2>&1
grep -Fq "Build mode: unsigned" "${TEMP_DIR}/unsigned-release.log"
grep -Fq "Configuration: Release" "${TEMP_DIR}/unsigned-release.log"
grep -Fq "unsigned Release는 임시 패키징/UI 확인용입니다." \
  "${TEMP_DIR}/unsigned-release.log"

run_preflight "${BUILD_SCRIPT}" --unsigned --open \
  >"${TEMP_DIR}/unsigned-open.log" 2>&1
grep -Fq "Build mode: unsigned" "${TEMP_DIR}/unsigned-open.log"

echo "macOS signing configuration tests passed"
