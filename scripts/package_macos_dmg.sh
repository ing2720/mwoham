#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.1.0"
APP_PATH=""
OUTPUT_DIR="${ROOT_DIR}/dist"
WHISPER_CLI_PATH="/opt/homebrew/bin/whisper-cli"
STT_MODEL_PATH="${HOME}/Library/Application Support/Mwoham/models/ggml-large-v3-turbo.bin"
SKIP_BUILD=0
SKIP_SIGN=0
INTERNAL_QA=0
SIGN_IDENTITY="${MWOHAM_CODE_SIGN_IDENTITY:-}"
SIGNING_CONFIG_PATH="${MWOHAM_SIGNING_CONFIG:-${HOME}/.config/mwoham/macos-signing.env}"
MODEL_NAME="ggml-large-v3-turbo.bin"
MIN_MODEL_BYTES=$((100 * 1024 * 1024))

usage() {
  cat <<'EOF'
Usage:
  ./scripts/package_macos_dmg.sh [--version 0.1.0] [--internal-qa]

Options:
  --app-path PATH             Existing MwohamMac.app path. Default: ~/Applications/MwohamMac.app
  --version VERSION           DMG version. Default: 0.1.0
  --whisper-cli-path PATH     whisper-cli source path. Default: /opt/homebrew/bin/whisper-cli
  --stt-model-path PATH       GGML model source path.
  --output-dir DIR            Output directory. Default: dist
  --skip-build                Reuse --app-path instead of building the app.
  --skip-sign                 Do not re-sign the app after resource injection.
  --sign-identity IDENTITY    codesign identity for re-signing.
  --internal-qa               Allow unsigned/ad-hoc internal QA packaging.

This script creates a first-pass DMG for internal QA. Developer ID signing and
notarization are intentionally not performed here.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

absolute_path() {
  local path="$1"
  if [[ "${path}" = /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s\n' "${ROOT_DIR}/${path}"
  fi
}

require_file() {
  local path="$1"
  local label="$2"
  [[ -f "${path}" ]] || fail "${label} not found: ${path}"
}

require_command() {
  local command_name="$1"
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} not found"
}

require_bundle_dylib() {
  local path="$1"
  local label="$2"
  [[ -f "${path}" ]] || fail "${label} dylib not found: ${path}"
}

copy_executable() {
  local source="$1"
  local target="$2"
  cp -pL "${source}" "${target}"
  chmod u+w,go-w "${target}"
  chmod +x "${target}"
}

copy_dylib() {
  local source="$1"
  local target="$2"
  cp -pL "${source}" "${target}"
  chmod u+w,go-w "${target}"
}

existing_app_signing_identity() {
  local app_path="$1"

  codesign -dv --verbose=4 "${app_path}" 2>&1 \
    | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p' \
    | head -n 1
}

patch_stt_install_names() {
  local stt_dir="$1"
  local cli_path="${stt_dir}/whisper-cli"
  local lib_dir="${stt_dir}/lib"
  local libwhisper="${lib_dir}/libwhisper.1.dylib"
  local libggml="${lib_dir}/libggml.0.dylib"
  local libggml_base="${lib_dir}/libggml-base.0.dylib"
  local libomp="${lib_dir}/libomp.dylib"

  install_name_tool -change "@rpath/libwhisper.1.dylib" \
    "@executable_path/lib/libwhisper.1.dylib" "${cli_path}" || true
  install_name_tool -change "/opt/homebrew/opt/ggml/lib/libggml.0.dylib" \
    "@executable_path/lib/libggml.0.dylib" "${cli_path}" || true
  install_name_tool -change "/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib" \
    "@executable_path/lib/libggml-base.0.dylib" "${cli_path}" || true

  install_name_tool -id "@rpath/libwhisper.1.dylib" "${libwhisper}"
  install_name_tool -change "/opt/homebrew/opt/ggml/lib/libggml.0.dylib" \
    "@loader_path/libggml.0.dylib" "${libwhisper}" || true
  install_name_tool -change "/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib" \
    "@loader_path/libggml-base.0.dylib" "${libwhisper}" || true

  install_name_tool -id "@rpath/libggml.0.dylib" "${libggml}"
  install_name_tool -change "@rpath/libggml-base.0.dylib" \
    "@loader_path/libggml-base.0.dylib" "${libggml}" || true

  install_name_tool -id "@rpath/libggml-base.0.dylib" "${libggml_base}"
  install_name_tool -change "/opt/homebrew/opt/libomp/lib/libomp.dylib" \
    "@loader_path/libomp.dylib" "${libggml_base}" || true

  install_name_tool -id "@rpath/libomp.dylib" "${libomp}"
}

bundle_stt_resources() {
  local app_path="$1"
  local stt_dir="${app_path}/Contents/Resources/STT"
  local model_dir="${stt_dir}/models"
  local lib_dir="${stt_dir}/lib"
  local model_bytes

  require_file "${WHISPER_CLI_PATH}" "whisper-cli"
  require_file "${STT_MODEL_PATH}" "STT model"
  require_bundle_dylib "/opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib" "whisper-cpp"
  require_bundle_dylib "/opt/homebrew/opt/ggml/lib/libggml.0.dylib" "ggml"
  require_bundle_dylib "/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib" "ggml-base"
  require_bundle_dylib "/opt/homebrew/opt/libomp/lib/libomp.dylib" "libomp"

  model_bytes="$(stat -f%z "${STT_MODEL_PATH}")"
  if [[ "${model_bytes}" -lt "${MIN_MODEL_BYTES}" ]]; then
    fail "STT model file is too small: ${STT_MODEL_PATH} (${model_bytes} bytes)"
  fi

  mkdir -p "${model_dir}" "${lib_dir}"
  copy_executable "${WHISPER_CLI_PATH}" "${stt_dir}/whisper-cli"
  cp -p "${STT_MODEL_PATH}" "${model_dir}/${MODEL_NAME}"

  copy_dylib "/opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib" \
    "${lib_dir}/libwhisper.1.dylib"
  copy_dylib "/opt/homebrew/opt/ggml/lib/libggml.0.dylib" \
    "${lib_dir}/libggml.0.dylib"
  copy_dylib "/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib" \
    "${lib_dir}/libggml-base.0.dylib"
  copy_dylib "/opt/homebrew/opt/libomp/lib/libomp.dylib" \
    "${lib_dir}/libomp.dylib"

  patch_stt_install_names "${stt_dir}"
}

write_install_readme() {
  local path="$1"
  cat > "${path}" <<'EOF'
# Mwoham 설치 안내

1. DMG 안의 `MwohamMac.app`을 `Applications` 바로가기로 드래그합니다.
2. DMG 내부에서 바로 실행하지 말고, Applications 폴더로 옮긴 앱을 실행합니다.
3. 첫 실행 후 macOS 시스템 설정에서 필요한 권한을 허용합니다.

앱이 열리지 않는 경우:

1. `MwohamMac.app`을 Applications 폴더로 옮깁니다.
2. 한 번 실행을 시도합니다.
3. 차단되면 시스템 설정 → 개인정보 보호 및 보안으로 이동합니다.
4. 아래쪽 보안 영역에서 `MwohamMac.app` 차단 메시지를 찾습니다.
5. “그래도 열기” 또는 “Open Anyway”를 누릅니다.
6. 다시 앱을 실행합니다.

터미널 방식:

```bash
xattr -dr com.apple.quarantine /Applications/MwohamMac.app
open /Applications/MwohamMac.app
```

필요 권한:

- 접근성: 활성 앱/창 상태 수집
- 마이크: 회의 마이크 전사
- 음성 인식: Apple Speech fallback
- 화면 기록: OCR, 시스템 오디오/회의 전체 전사

STT:

- Mwoham은 로컬 Whisper STT를 사용합니다.
- 이 DMG에는 `whisper-cli`와 `ggml-large-v3-turbo.bin` 모델이 포함되어 있습니다.
- 별도 STT API key는 필요하지 않습니다.

Backend 경로:

- 앱은 backend를 고정 설치 경로로 찾지 않습니다.
- backend가 앱에 포함된 배포판이면 현재 실행 중인 앱 기준
  `MwohamMac.app/Contents/Resources/backend`를 자동으로 사용합니다.
- backend가 앱에 포함되지 않은 내부 QA 빌드이면 앱 설정 > 백엔드에서
  backend 폴더를 직접 선택합니다.
- 개발/QA repo를 함께 받은 경우 일반적인 backend 폴더는 다음 경로입니다.

```text
/Users/a/Projects/mwoham/backend
```

- 설정에서 backend 경로를 비우고 `자동 탐색`을 누르면 앱은 현재 앱 번들,
  Application Support, 개발 빌드 fallback 순서로 다시 확인합니다.

AI 리포트:

- AI 리포트 품질을 높이려면 앱 설정에서 Gemini 또는 OpenAI API Key를 입력합니다.
- API Key는 macOS Keychain에 저장됩니다.
- API Key가 없거나 quota/API/timeout 실패가 발생하면 fallback 리포트가 생성됩니다.

주의:

- 본 DMG는 내부 QA/포트폴리오 시연용입니다.
- Developer ID signing/notarization이 적용되지 않아 Gatekeeper 경고가 표시될 수 있습니다.
- 앱은 반드시 DMG 내부에서 바로 실행하지 말고 Applications 폴더로 옮긴 뒤 실행해야 합니다.
EOF
}

create_dmg() {
  local app_path="$1"
  local dmg_path="$2"
  local staging_dir="${OUTPUT_DIR}/dmg-staging"

  rm -rf "${staging_dir}"
  mkdir -p "${staging_dir}"
  ditto "${app_path}" "${staging_dir}/MwohamMac.app"
  ln -s /Applications "${staging_dir}/Applications"
  write_install_readme "${staging_dir}/README_INSTALL.md"

  rm -f "${dmg_path}"
  hdiutil create \
    -volname "Mwoham ${VERSION}" \
    -srcfolder "${staging_dir}" \
    -ov \
    -format UDZO \
    "${dmg_path}"
  hdiutil verify "${dmg_path}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      [[ $# -ge 2 ]] || fail "--app-path requires a value"
      APP_PATH="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --whisper-cli-path)
      [[ $# -ge 2 ]] || fail "--whisper-cli-path requires a value"
      WHISPER_CLI_PATH="$2"
      shift 2
      ;;
    --stt-model-path)
      [[ $# -ge 2 ]] || fail "--stt-model-path requires a value"
      STT_MODEL_PATH="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir requires a value"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --skip-sign)
      SKIP_SIGN=1
      shift
      ;;
    --sign-identity)
      [[ $# -ge 2 ]] || fail "--sign-identity requires a value"
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --internal-qa)
      INTERNAL_QA=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

OUTPUT_DIR="$(absolute_path "${OUTPUT_DIR}")"
if [[ -z "${APP_PATH}" ]]; then
  APP_PATH="${HOME}/Applications/MwohamMac.app"
else
  APP_PATH="$(absolute_path "${APP_PATH}")"
fi
DMG_PATH="${OUTPUT_DIR}/Mwoham-${VERSION}.dmg"

if [[ -f "${SIGNING_CONFIG_PATH}" ]]; then
  # shellcheck disable=SC1090
  source "${SIGNING_CONFIG_PATH}"
fi
SIGN_IDENTITY="${MWOHAM_CODE_SIGN_IDENTITY:-${SIGN_IDENTITY}}"

require_command xcodebuild
require_command hdiutil
require_command install_name_tool
require_command otool
require_command codesign

mkdir -p "${OUTPUT_DIR}"

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  BUILD_ARGS=(--release --destination "${APP_PATH}")
  if [[ "${INTERNAL_QA}" -eq 1 ]]; then
    BUILD_ARGS=(--unsigned "${BUILD_ARGS[@]}")
  fi
  MWOHAM_SKIP_LSREGISTER=1 "${ROOT_DIR}/scripts/build_macos_app.sh" "${BUILD_ARGS[@]}"
else
  [[ -d "${APP_PATH}" ]] || fail "app bundle not found: ${APP_PATH}"
fi

bundle_stt_resources "${APP_PATH}"
"${ROOT_DIR}/scripts/check_release_stt_resources.sh" "${APP_PATH}"

if [[ "${SKIP_SIGN}" -eq 0 ]]; then
  if [[ -z "${SIGN_IDENTITY}" ]]; then
    SIGN_IDENTITY="$(existing_app_signing_identity "${APP_PATH}")"
  fi

  if [[ -n "${SIGN_IDENTITY}" ]]; then
    codesign --force --deep --options runtime --sign "${SIGN_IDENTITY}" "${APP_PATH}"
  elif [[ "${INTERNAL_QA}" -eq 1 ]]; then
    echo "Warning: ad-hoc signing internal QA app bundle."
    codesign --force --deep --sign - "${APP_PATH}"
  else
    fail "no signing identity provided. Use --sign-identity or --internal-qa."
  fi
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
else
  echo "Warning: skipping app re-sign after resource injection."
fi

create_dmg "${APP_PATH}" "${DMG_PATH}"

echo "DMG created: ${DMG_PATH}"
echo "App bundle: ${APP_PATH}"
echo "STT runtime: ${APP_PATH}/Contents/Resources/STT/whisper-cli"
echo "STT model: ${APP_PATH}/Contents/Resources/STT/models/${MODEL_NAME}"
