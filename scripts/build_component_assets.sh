#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="1.1.0"
OUTPUT_DIR="${ROOT_DIR}/dist/components"
RELEASE_BASE_URL="${MWOHAM_COMPONENT_BASE_URL:-https://github.com/ing2720/mwoham/releases/download/v1.1.0}"
URL_CACHE_BUST="${MWOHAM_COMPONENT_URL_CACHE_BUST:-sha256}"
WHISPER_CLI_PATH="${MWOHAM_WHISPER_CLI_PATH:-/opt/homebrew/bin/whisper-cli}"
STT_MODEL_PATH="${MWOHAM_STT_MODEL_PATH:-}"
MODEL_NAME="ggml-large-v3-turbo.bin"
MIN_MODEL_BYTES=$((100 * 1024 * 1024))
GENERATED_SWIFT="${ROOT_DIR}/mac-client/MwohamMac/MwohamMac/GeneratedComponentSources.swift"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/build_component_assets.sh [--version 1.1.0] [--stt-model-path PATH]

Options:
  --version VERSION          Component version. Default: 1.1.0
  --output-dir DIR           Output directory. Default: dist/components
  --release-base-url URL     GitHub Release asset base URL.
  --url-cache-bust MODE      Query cache-bust mode for http(s) URLs: sha256, version, none. Default: sha256
  --whisper-cli-path PATH    whisper-cli source path. Default: /opt/homebrew/bin/whisper-cli
  --stt-model-path PATH      ggml-large-v3-turbo.bin source path. Can also use MWOHAM_STT_MODEL_PATH.

Outputs:
  dist/components/MwohamBackend-<version>.tar.gz
  dist/components/MwohamSTTRuntime-<version>.tar.gz
  dist/components/ggml-large-v3-turbo.bin, when --stt-model-path is available
  dist/components/sha256sums.txt
  dist/components/component_manifest.json
  mac-client/MwohamMac/MwohamMac/GeneratedComponentSources.swift
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

patch_stt_install_names() {
  local stt_dir="$1"
  local cli_path="${stt_dir}/bin/whisper-cli"
  local lib_dir="${stt_dir}/lib"
  local libwhisper="${lib_dir}/libwhisper.1.dylib"
  local libggml="${lib_dir}/libggml.0.dylib"
  local libggml_base="${lib_dir}/libggml-base.0.dylib"
  local libomp="${lib_dir}/libomp.dylib"

  install_name_tool -change "@rpath/libwhisper.1.dylib" \
    "@executable_path/../lib/libwhisper.1.dylib" "${cli_path}" || true
  install_name_tool -change "/opt/homebrew/opt/ggml/lib/libggml.0.dylib" \
    "@executable_path/../lib/libggml.0.dylib" "${cli_path}" || true
  install_name_tool -change "/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib" \
    "@executable_path/../lib/libggml-base.0.dylib" "${cli_path}" || true

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

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

release_asset_url() {
  local asset_name="$1"
  local asset_sha="$2"
  local url="${RELEASE_BASE_URL}/${asset_name}"

  case "${URL_CACHE_BUST}" in
    sha256)
      if [[ "${RELEASE_BASE_URL}" == http://* || "${RELEASE_BASE_URL}" == https://* ]]; then
        if [[ -n "${asset_sha}" ]]; then
          url="${url}?sha256=${asset_sha}"
        else
          url="${url}?version=${VERSION}"
        fi
      fi
      ;;
    version)
      if [[ "${RELEASE_BASE_URL}" == http://* || "${RELEASE_BASE_URL}" == https://* ]]; then
        url="${url}?version=${VERSION}"
      fi
      ;;
    none)
      ;;
    *)
      fail "unknown --url-cache-bust mode: ${URL_CACHE_BUST}"
      ;;
  esac

  printf '%s\n' "${url}"
}

write_generated_swift() {
  local backend_sha="$1"
  local stt_cli_sha="$2"
  local stt_model_sha="$3"
  local backend_url
  local stt_cli_url
  local stt_model_url
  backend_url="$(release_asset_url "MwohamBackend-${VERSION}.tar.gz" "${backend_sha}")"
  stt_cli_url="$(release_asset_url "MwohamSTTRuntime-${VERSION}.tar.gz" "${stt_cli_sha}")"
  stt_model_url="$(release_asset_url "${MODEL_NAME}" "${stt_model_sha}")"

  cat > "${GENERATED_SWIFT}" <<EOF
//
//  GeneratedComponentSources.swift
//  MwohamMac
//
//  Generated by scripts/build_component_assets.sh.
//

import Foundation

nonisolated enum ComponentSourceCatalog {
    static let v1_1_0 = ComponentDownloadConfig(
        version: "${VERSION}",
        baseURLString: "${RELEASE_BASE_URL}",
        sha256ByComponent: [
            .backend: "${backend_sha}",
            .sttCLI: "${stt_cli_sha}",
            .sttModel: "${stt_model_sha}",
        ],
        urlByComponent: [
            .backend: "${backend_url}",
            .sttCLI: "${stt_cli_url}",
            .sttModel: "${stt_model_url}",
        ]
    )
}
EOF
}

write_remote_manifest() {
  local backend_sha="$1"
  local stt_cli_sha="$2"
  local stt_model_sha="$3"
  local backend_url
  local stt_cli_url
  local stt_model_url
  backend_url="$(release_asset_url "MwohamBackend-${VERSION}.tar.gz" "${backend_sha}")"
  stt_cli_url="$(release_asset_url "MwohamSTTRuntime-${VERSION}.tar.gz" "${stt_cli_sha}")"
  stt_model_url="$(release_asset_url "${MODEL_NAME}" "${stt_model_sha}")"

  cat > "${OUTPUT_DIR}/component_manifest.json" <<EOF
{
  "version": "${VERSION}",
  "components": {
    "backend": {
      "version": "${VERSION}",
      "url": $(json_escape "${backend_url}"),
      "sha256": "${backend_sha}"
    },
    "sttCLI": {
      "version": "${VERSION}",
      "url": $(json_escape "${stt_cli_url}"),
      "sha256": "${stt_cli_sha}"
    },
    "sttModel": {
      "name": "${MODEL_NAME}",
      "version": "${VERSION}",
      "url": $(json_escape "${stt_model_url}"),
      "sha256": "${stt_model_sha}"
    }
  }
}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir requires a value"
      OUTPUT_DIR="$(absolute_path "$2")"
      shift 2
      ;;
    --release-base-url)
      [[ $# -ge 2 ]] || fail "--release-base-url requires a value"
      RELEASE_BASE_URL="$2"
      shift 2
      ;;
    --url-cache-bust)
      [[ $# -ge 2 ]] || fail "--url-cache-bust requires a value"
      URL_CACHE_BUST="$2"
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
BACKEND_ASSET="${OUTPUT_DIR}/MwohamBackend-${VERSION}.tar.gz"
STT_RUNTIME_ASSET="${OUTPUT_DIR}/MwohamSTTRuntime-${VERSION}.tar.gz"
MODEL_ASSET="${OUTPUT_DIR}/${MODEL_NAME}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mwoham-component-assets.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

mkdir -p "${OUTPUT_DIR}"
rm -f "${BACKEND_ASSET}" "${STT_RUNTIME_ASSET}" "${OUTPUT_DIR}/sha256sums.txt" "${OUTPUT_DIR}/component_manifest.json"

echo "Building backend component asset..."
tar \
  --exclude='.venv' \
  --exclude='__pycache__' \
  --exclude='.pytest_cache' \
  --exclude='.ruff_cache' \
  --exclude='.mypy_cache' \
  --exclude='.coverage' \
  --exclude='htmlcov' \
  --exclude='*.db' \
  --exclude='*.sqlite3' \
  --exclude='logs' \
  --exclude='data' \
  --exclude='.env' \
  -czf "${BACKEND_ASSET}" \
  -C "${ROOT_DIR}/backend" \
  .

echo "Building STT runtime component asset..."
require_file "${WHISPER_CLI_PATH}" "whisper-cli"
require_file "/opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib" "whisper-cpp dylib"
require_file "/opt/homebrew/opt/ggml/lib/libggml.0.dylib" "ggml dylib"
require_file "/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib" "ggml-base dylib"
require_file "/opt/homebrew/opt/libomp/lib/libomp.dylib" "libomp dylib"

STT_STAGE="${WORK_DIR}/stt-runtime"
mkdir -p "${STT_STAGE}/bin" "${STT_STAGE}/lib"
copy_executable "${WHISPER_CLI_PATH}" "${STT_STAGE}/bin/whisper-cli"
copy_dylib "/opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib" "${STT_STAGE}/lib/libwhisper.1.dylib"
copy_dylib "/opt/homebrew/opt/ggml/lib/libggml.0.dylib" "${STT_STAGE}/lib/libggml.0.dylib"
copy_dylib "/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib" "${STT_STAGE}/lib/libggml-base.0.dylib"
copy_dylib "/opt/homebrew/opt/libomp/lib/libomp.dylib" "${STT_STAGE}/lib/libomp.dylib"
patch_stt_install_names "${STT_STAGE}"
tar -czf "${STT_RUNTIME_ASSET}" -C "${STT_STAGE}" .

MODEL_SHA=""
if [[ -n "${STT_MODEL_PATH}" ]]; then
  STT_MODEL_PATH="$(absolute_path "${STT_MODEL_PATH}")"
  require_file "${STT_MODEL_PATH}" "STT model"
  MODEL_BYTES="$(stat -f%z "${STT_MODEL_PATH}")"
  if [[ "${MODEL_BYTES}" -lt "${MIN_MODEL_BYTES}" ]]; then
    fail "STT model file is too small: ${STT_MODEL_PATH} (${MODEL_BYTES} bytes)"
  fi
  cp -p "${STT_MODEL_PATH}" "${MODEL_ASSET}"
  MODEL_SHA="$(sha256 "${MODEL_ASSET}")"
else
  echo "Warning: STT model source not provided; ${MODEL_NAME} was not copied." >&2
  echo "Warning: rerun with --stt-model-path PATH or MWOHAM_STT_MODEL_PATH=PATH before publishing v${VERSION}." >&2
fi

BACKEND_SHA="$(sha256 "${BACKEND_ASSET}")"
STT_RUNTIME_SHA="$(sha256 "${STT_RUNTIME_ASSET}")"

{
  printf '%s  %s\n' "${BACKEND_SHA}" "$(basename "${BACKEND_ASSET}")"
  printf '%s  %s\n' "${STT_RUNTIME_SHA}" "$(basename "${STT_RUNTIME_ASSET}")"
  if [[ -n "${MODEL_SHA}" ]]; then
    printf '%s  %s\n' "${MODEL_SHA}" "$(basename "${MODEL_ASSET}")"
  else
    printf '%s  %s\n' "MISSING_MODEL_SHA256" "$(basename "${MODEL_ASSET}")"
  fi
} > "${OUTPUT_DIR}/sha256sums.txt"

write_remote_manifest "${BACKEND_SHA}" "${STT_RUNTIME_SHA}" "${MODEL_SHA}"
write_generated_swift "${BACKEND_SHA}" "${STT_RUNTIME_SHA}" "${MODEL_SHA}"

echo "Component assets:"
ls -lh "${OUTPUT_DIR}"
echo
echo "sha256sums:"
cat "${OUTPUT_DIR}/sha256sums.txt"
echo
echo "App component source config updated:"
echo "${GENERATED_SWIFT}"
