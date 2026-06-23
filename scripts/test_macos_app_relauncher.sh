#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/mac-client/MwohamMac/MwohamMac"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mwoham-app-relauncher.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

let command = AppRelauncher.relaunchCommand(
    bundlePath: "/Users/a/Applications/MwohamMac.app",
    delaySeconds: 0.25,
    currentProcessID: 12345
)
expect(command.contains("/bin/kill -0 12345"), "relaunch command waits for the current app process")
expect(command.contains("[ $i -lt 80 ]"), "relaunch command caps process wait attempts")
expect(command.contains("sleep 0.25"), "relaunch command delays before opening")
expect(command.contains("/usr/bin/open -n"), "relaunch command forces a new app instance")
expect(
    command.contains("'/Users/a/Applications/MwohamMac.app'"),
    "relaunch command shell-quotes the bundle path"
)

let quoted = AppRelauncher.relaunchCommand(
    bundlePath: "/tmp/Mwoham's App/MwohamMac.app",
    currentProcessID: 12345
)
expect(
    quoted.contains("'/tmp/Mwoham'\\''s App/MwohamMac.app'"),
    "relaunch command escapes single quotes"
)

print("macOS app relauncher tests passed")
SWIFT

swiftc \
    -module-cache-path "$WORK_DIR/module-cache" \
    "$WORK_DIR/main.swift" \
    "$APP_DIR/AppRelauncher.swift" \
    -o "$WORK_DIR/app_relauncher_harness"

"$WORK_DIR/app_relauncher_harness"
