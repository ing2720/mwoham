#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${ROOT_DIR}/mac-client/MwohamMac/MwohamMac.xcodeproj"
SCHEME="MwohamMac"
CONFIGURATION="Debug"
DERIVED_DATA_PATH="${ROOT_DIR}/.derivedData/MwohamMac"
APP_PATH="${APP_PATH:-${HOME}/Applications/MwohamMac.app}"
EXPECTED_BUNDLE_IDENTIFIER="com.ing2720.MwohamMac"
EXPECTED_DISPLAY_NAME="MwohamMac"
SIGNING_CONFIG_PATH="${MWOHAM_SIGNING_CONFIG:-${HOME}/.config/mwoham/macos-signing.env}"
SIGNING_IDENTITY="${MWOHAM_CODE_SIGN_IDENTITY:-}"
DEVELOPMENT_TEAM="${MWOHAM_DEVELOPMENT_TEAM:-}"
SHOULD_OPEN=0
ALLOW_UNSIGNED=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/build_macos_app.sh [--release] [--open] [--destination /path/to/MwohamMac.app]
  ./scripts/build_macos_app.sh --unsigned [--release] [--open] [--destination /path/to/MwohamMac.app]

Builds and installs MwohamMac into a stable bundle path.
Default configuration: Debug
Default destination: ~/Applications/MwohamMac.app

Signing configuration:
  ~/.config/mwoham/macos-signing.env

Required values:
  MWOHAM_DEVELOPMENT_TEAM=YOUR_TEAM_ID

Optional value:
  MWOHAM_CODE_SIGN_IDENTITY="Apple Development: name@example.com (YOUR_TEAM_ID)"

Without an explicit identity, the script selects the Apple Development identity
whose certificate name contains the configured Team ID.

--unsigned allows UI/CI builds without a Team ID or certificate. TCC permissions
are not stable in that mode.

--release builds the Release configuration. A signed Release build is recommended
for installed-app and macOS permission/TCC verification.
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

available_signing_identities() {
  if [[ -n "${MWOHAM_SECURITY_IDENTITIES+x}" ]]; then
    printf '%s\n' "${MWOHAM_SECURITY_IDENTITIES}"
    return
  fi
  security find-identity -v -p codesigning 2>&1 || true
}

certificate_team_id() {
  local identity="$1"

  if [[ -n "${MWOHAM_CERTIFICATE_TEAM_ID+x}" ]]; then
    printf '%s\n' "${MWOHAM_CERTIFICATE_TEAM_ID}"
    return
  fi

  security find-certificate -c "${identity}" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -E 's/.*OU=([^,]+).*/\1/'
}

resolve_signing_identity_line() {
  local identities="$1"
  local requested_identity="$2"
  local identity
  local certificate_team
  local line

  if [[ -n "${requested_identity}" ]]; then
    line="$(
      printf '%s\n' "${identities}" \
        | grep -F "\"${requested_identity}\"" \
        | head -n 1 || true
    )"
    if [[ -z "${line}" ]]; then
      return 1
    fi
    identity="$(
      printf '%s\n' "${line}" \
        | sed -E 's/^[^"]*"([^"]+)".*$/\1/'
    )"
    certificate_team="$(certificate_team_id "${identity}")"
    if [[ "${certificate_team}" != "${DEVELOPMENT_TEAM}" ]]; then
      return 1
    fi
    printf '%s\n' "${line}"
    return
  fi

  while IFS= read -r line; do
    if [[ "${line}" != *'"Apple Development:'* ]]; then
      continue
    fi
    identity="$(
      printf '%s\n' "${line}" \
        | sed -E 's/^[^"]*"([^"]+)".*$/\1/'
    )"
    certificate_team="$(certificate_team_id "${identity}")"
    if [[ "${certificate_team}" == "${DEVELOPMENT_TEAM}" ]]; then
      printf '%s\n' "${line}"
      return
    fi
  done <<<"${identities}"

  return 1
}

print_build_settings() {
  local identity="${1:-Apple Development}"
  local signing_style="${2:-Automatic}"

  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "platform=macOS" \
    "MWOHAM_DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}" \
    "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}" \
    "CODE_SIGN_IDENTITY=${identity}" \
    "CODE_SIGN_STYLE=${signing_style}" \
    -showBuildSettings 2>/dev/null \
    | grep -E '^[[:space:]]*(CODE_SIGN_IDENTITY|CODE_SIGN_STYLE|DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER)[[:space:]]*=' \
    || true
}

print_signing_diagnostics() {
  local identity="${1:-Apple Development}"
  local signing_style="${2:-Automatic}"

  echo "Signing diagnostics:" >&2
  echo "Available code signing identities:" >&2
  available_signing_identities >&2
  echo "Resolved build settings:" >&2
  print_build_settings "${identity}" "${signing_style}" >&2
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
    --unsigned)
      ALLOW_UNSIGNED=1
      shift
      ;;
    --release)
      CONFIGURATION="Release"
      shift
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
BUILT_APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/MwohamMac.app"

if [[ -f "${SIGNING_CONFIG_PATH}" ]]; then
  # shellcheck disable=SC1090
  source "${SIGNING_CONFIG_PATH}"
fi
DEVELOPMENT_TEAM="${MWOHAM_DEVELOPMENT_TEAM:-${DEVELOPMENT_TEAM}}"
SIGNING_IDENTITY="${MWOHAM_CODE_SIGN_IDENTITY:-${SIGNING_IDENTITY}}"

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

XCODEBUILD_ARGUMENTS=(
  -project "${PROJECT_PATH}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -destination "platform=macOS"
  -derivedDataPath "${DERIVED_DATA_PATH}"
)

if [[ "${ALLOW_UNSIGNED}" -eq 1 ]]; then
  BUILD_MODE="unsigned"
  DISPLAY_TEAM_ID="none"
  RESOLVED_SIGNING_IDENTITY="none"
  RESOLVED_SIGNING_IDENTITY_HASH="none"
  RESOLVED_SIGNING_STYLE="none"
  echo "Warning: unsigned/ad-hoc build입니다."
  echo "Warning: macOS 권한/TCC 상태가 안정적으로 유지되지 않을 수 있습니다."
  echo "Warning: 마이크/화면 기록/접근성 권한 테스트에는 signed build를 사용하세요."
  if [[ "${CONFIGURATION}" == "Release" ]]; then
    echo "Warning: unsigned Release는 임시 패키징/UI 확인용입니다."
  fi
  XCODEBUILD_ARGUMENTS+=(CODE_SIGNING_ALLOWED=NO)
else
  BUILD_MODE="signed"
  DISPLAY_TEAM_ID="${DEVELOPMENT_TEAM}"
  if [[ -z "${DEVELOPMENT_TEAM}" ]]; then
    echo "MWOHAM_DEVELOPMENT_TEAM is required for a stable signed app." >&2
    echo "Create ${SIGNING_CONFIG_PATH} with:" >&2
    echo "  MWOHAM_DEVELOPMENT_TEAM=YOUR_TEAM_ID" >&2
    print_signing_diagnostics "${SIGNING_IDENTITY:-Apple Development}" "Automatic"
    exit 1
  fi

  SIGNING_IDENTITIES="$(available_signing_identities)"
  if ! RESOLVED_SIGNING_IDENTITY_LINE="$(
    resolve_signing_identity_line "${SIGNING_IDENTITIES}" "${SIGNING_IDENTITY}"
  )"; then
    echo "Apple Development identity not found for Team ID ${DEVELOPMENT_TEAM}." >&2
    if [[ -n "${SIGNING_IDENTITY}" ]]; then
      echo "Requested identity: ${SIGNING_IDENTITY}" >&2
    fi
    echo "Open Xcode > Settings > Accounts and install an Apple Development certificate." >&2
    echo "The certificate Team ID is its subject OU, not necessarily the suffix in its display name." >&2
    print_signing_diagnostics "${SIGNING_IDENTITY:-Apple Development}" "Manual"
    exit 1
  fi

  RESOLVED_SIGNING_IDENTITY="$(
    printf '%s\n' "${RESOLVED_SIGNING_IDENTITY_LINE}" \
      | sed -E 's/^[^"]*"([^"]+)".*$/\1/'
  )"
  RESOLVED_SIGNING_IDENTITY_HASH="$(
    printf '%s\n' "${RESOLVED_SIGNING_IDENTITY_LINE}" \
      | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]+).*/\1/'
  )"
  RESOLVED_SIGNING_STYLE="Manual"
  XCODEBUILD_ARGUMENTS+=(
    "MWOHAM_DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
    "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
    "CODE_SIGN_IDENTITY=${RESOLVED_SIGNING_IDENTITY_HASH}"
    "CODE_SIGN_STYLE=${RESOLVED_SIGNING_STYLE}"
  )
fi

echo "Build mode: ${BUILD_MODE}"
echo "Configuration: ${CONFIGURATION}"
echo "Bundle ID: ${EXPECTED_BUNDLE_IDENTIFIER}"
echo "Team ID: ${DISPLAY_TEAM_ID:-none}"
echo "Resolved signing identity: ${RESOLVED_SIGNING_IDENTITY}"
echo "Resolved signing identity fingerprint: ${RESOLVED_SIGNING_IDENTITY_HASH}"
echo "Resolved signing style: ${RESOLVED_SIGNING_STYLE}"
echo "App output path: ${APP_PATH}"
echo "DerivedData: ${DERIVED_DATA_PATH}"
if [[ "${BUILD_MODE}" == "signed" && "${CONFIGURATION}" == "Release" ]]; then
  echo "Install profile: signed Release (recommended for installed-app/TCC QA)"
elif [[ "${BUILD_MODE}" == "signed" ]]; then
  echo "Install profile: signed Debug (development and permission QA)"
else
  echo "Install profile: unsigned ${CONFIGURATION} (temporary UI/CI use only)"
fi

if [[ "${MWOHAM_BUILD_PREFLIGHT_ONLY:-0}" == "1" ]]; then
  echo "Preflight-only mode: build skipped."
  exit 0
fi

xcodebuild -version

if ! xcodebuild "${XCODEBUILD_ARGUMENTS[@]}" build; then
  echo "MwohamMac ${BUILD_MODE} build failed." >&2
  if [[ "${ALLOW_UNSIGNED}" -eq 0 ]]; then
    print_signing_diagnostics \
      "${RESOLVED_SIGNING_IDENTITY_HASH}" \
      "${RESOLVED_SIGNING_STYLE}"
    echo "The build stopped without falling back to unsigned mode." >&2
  fi
  exit 1
fi

if [[ ! -d "${BUILT_APP_PATH}" ]]; then
  echo "Built app not found: ${BUILT_APP_PATH}" >&2
  exit 1
fi

echo "Installing MwohamMac..."
echo "1/5 Stopping the existing MwohamMac process if present..."
pkill -x MwohamMac 2>/dev/null || true
for _ in {1..30}; do
  if ! pgrep -x MwohamMac >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if pgrep -x MwohamMac >/dev/null 2>&1; then
  echo "MwohamMac is still running; refusing to replace the app bundle." >&2
  exit 1
fi

echo "2/5 Replacing the installed app bundle..."
echo "From: ${BUILT_APP_PATH}"
echo "To:   ${APP_PATH}"
mkdir -p "$(dirname "${APP_PATH}")"
rm -rf "${APP_PATH}"
ditto "${BUILT_APP_PATH}" "${APP_PATH}"

ACTUAL_BUNDLE_IDENTIFIER="$(
  /usr/libexec/PlistBuddy \
    -c "Print :CFBundleIdentifier" \
    "${APP_PATH}/Contents/Info.plist"
)"
if [[ "${ACTUAL_BUNDLE_IDENTIFIER}" != "${EXPECTED_BUNDLE_IDENTIFIER}" ]]; then
  echo "Unexpected bundle identifier: ${ACTUAL_BUNDLE_IDENTIFIER}" >&2
  exit 1
fi

ACTUAL_DISPLAY_NAME="$(
  /usr/libexec/PlistBuddy \
    -c "Print :CFBundleDisplayName" \
    "${APP_PATH}/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy \
      -c "Print :CFBundleName" \
      "${APP_PATH}/Contents/Info.plist"
)"
if [[ "${ACTUAL_DISPLAY_NAME}" != "${EXPECTED_DISPLAY_NAME}" ]]; then
  echo "Unexpected app display name: ${ACTUAL_DISPLAY_NAME}" >&2
  exit 1
fi

MARKETING_VERSION="$(
  /usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" \
    "${APP_PATH}/Contents/Info.plist"
)"
BUILD_NUMBER="$(
  /usr/libexec/PlistBuddy \
    -c "Print :CFBundleVersion" \
    "${APP_PATH}/Contents/Info.plist"
)"

if [[ "${ALLOW_UNSIGNED}" -eq 0 ]]; then
  echo "3/5 Verifying the signed app bundle..."
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
  SIGNING_DETAILS="$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1)"
  if grep -Fq "Signature=adhoc" <<<"${SIGNING_DETAILS}"; then
    echo "Stable install must not use an ad-hoc signature." >&2
    exit 1
  fi
  if ! grep -Fq "TeamIdentifier=${DEVELOPMENT_TEAM}" <<<"${SIGNING_DETAILS}"; then
    echo "Signed app TeamIdentifier does not match ${DEVELOPMENT_TEAM}." >&2
    exit 1
  fi
  echo "${SIGNING_DETAILS}" \
    | grep -E "^(Identifier|Authority|TeamIdentifier|Signature)="
  codesign -d -r- "${APP_PATH}" 2>&1
else
  echo "3/5 Skipping codesign identity verification for explicit unsigned mode."
fi

if [[ "${MWOHAM_SKIP_LSREGISTER:-0}" == "1" ]]; then
  echo "4/5 Skipping LaunchServices registration."
else
  echo "4/5 Registering the installed app with LaunchServices..."
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" \
    -f "${APP_PATH}"
fi

echo "5/5 Installation complete."
echo "Installed app: ${APP_PATH}"
echo "Display name: ${ACTUAL_DISPLAY_NAME}"
echo "Bundle ID: ${ACTUAL_BUNDLE_IDENTIFIER}"
echo "Version: ${MARKETING_VERSION} (${BUILD_NUMBER})"
echo "Configuration: ${CONFIGURATION}"
echo "Build mode: ${BUILD_MODE}"

if [[ "${SHOULD_OPEN}" -eq 1 ]]; then
  if [[ "${ALLOW_UNSIGNED}" -eq 1 ]]; then
    echo "Warning: opening an unsigned/ad-hoc app for temporary UI verification."
  fi
  echo "Opening app..."
  open -n "${APP_PATH}"
fi
