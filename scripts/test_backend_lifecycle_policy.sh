#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_TYPES="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/StatusTypes.swift"
LIFECYCLE_STATE="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/BackendLifecycleState.swift"
WORK_DIR="$(mktemp -d /private/tmp/mwoham-backend-lifecycle.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("failed: \(message)\n", stderr)
        exit(1)
    }
}

expect(
    BackendLifecyclePolicy.preflight(
        healthAvailable: false,
        portInUse: false,
        backendDirectoryExists: true,
        uvExecutablePath: "/opt/homebrew/bin/uv"
    ) == .ready("/opt/homebrew/bin/uv"),
    "valid backend path and uv should be ready"
)
expect(
    BackendLifecyclePolicy.preflight(
        healthAvailable: false,
        portInUse: false,
        backendDirectoryExists: false,
        uvExecutablePath: "/opt/homebrew/bin/uv"
    ) == .backendPathMissing,
    "missing backend path should be distinguished"
)
expect(
    BackendLifecyclePolicy.preflight(
        healthAvailable: false,
        portInUse: false,
        backendDirectoryExists: true,
        uvExecutablePath: nil
    ) == .uvMissing,
    "missing uv should be distinguished"
)
expect(
    BackendLifecyclePolicy.preflight(
        healthAvailable: false,
        portInUse: true,
        backendDirectoryExists: true,
        uvExecutablePath: "/opt/homebrew/bin/uv"
    ) == .portConflict,
    "occupied unhealthy port should be a conflict"
)
expect(
    BackendLifecyclePolicy.canStopBackend(isOwnedByApp: true),
    "app-owned backend can be stopped"
)
expect(
    !BackendLifecyclePolicy.canStopBackend(isOwnedByApp: false),
    "external backend cannot be stopped"
)
expect(BackendLifecycleState.starting.isRunning, "starting is active")
expect(BackendLifecycleState.portConflict.isError, "port conflict is an error")

print("backend lifecycle policy tests passed")
SWIFT

CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache" swiftc \
    "$WORK_DIR/main.swift" \
    "$STATUS_TYPES" \
    "$LIFECYCLE_STATE" \
    -o "$WORK_DIR/harness"
"$WORK_DIR/harness"

