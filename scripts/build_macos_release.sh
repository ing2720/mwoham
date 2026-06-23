#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "build_macos_release.sh delegates to the stable packaging workflow."
MWOHAM_BUNDLE_COMPONENTS="${MWOHAM_BUNDLE_COMPONENTS:-0}" \
  exec "${ROOT_DIR}/scripts/build_macos_app.sh" --release "$@"
