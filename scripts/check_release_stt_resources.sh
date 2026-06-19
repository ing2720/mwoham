#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/check_release_stt_resources.sh /path/to/MwohamMac.app

Checks that a built MwohamMac.app contains the bundled Local Whisper runtime
resources expected by release packaging. This script does not create a DMG.
EOF
}

if [[ $# -ne 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  if [[ $# -eq 1 ]]; then
    exit 0
  fi
  exit 1
fi

APP_PATH="$1"
STT_DIR="$APP_PATH/Contents/Resources/STT"
CLI_PATH="$STT_DIR/whisper-cli"
MODEL_PATH="$STT_DIR/models/ggml-large-v3-turbo.bin"
MIN_MODEL_BYTES=$((100 * 1024 * 1024))

if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
  echo "MwohamMac.app 경로가 아닙니다: $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$CLI_PATH" ]]; then
  echo "Whisper 실행 파일이 누락되었습니다: $CLI_PATH" >&2
  exit 1
fi

if [[ ! -x "$CLI_PATH" ]]; then
  echo "Whisper 실행 파일에 실행 권한이 없습니다: $CLI_PATH" >&2
  exit 1
fi

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "large-v3-turbo 모델 파일이 누락되었습니다: $MODEL_PATH" >&2
  exit 1
fi

MODEL_BYTES="$(stat -f%z "$MODEL_PATH")"
if [[ "$MODEL_BYTES" -lt "$MIN_MODEL_BYTES" ]]; then
  echo "모델 파일 크기가 비정상적으로 작습니다: $MODEL_PATH ($MODEL_BYTES bytes)" >&2
  exit 1
fi

echo "STT release resources look ready:"
echo "- $CLI_PATH"
echo "- $MODEL_PATH ($MODEL_BYTES bytes)"
