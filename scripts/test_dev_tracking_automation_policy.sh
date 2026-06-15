#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/DevTrackingAutomationPolicy.swift"
WORK_DIR="$(mktemp -d /private/tmp/mwoham-dev-tracking-policy.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("failed: \(message)\n", stderr)
        exit(1)
    }
}

let repoURL = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["MWOHAM_REPO_ROOT"]!
)
expect(DevTrackingAutomationPolicy.action(for: .started) == .start, "start transition")
expect(DevTrackingAutomationPolicy.action(for: .stopped) == .stop, "stop transition")
expect(DevTrackingAutomationPolicy.action(for: .paused) == .none, "pause transition")
expect(DevTrackingAutomationPolicy.action(for: .resumed) == .none, "resume transition")
expect(
    DevTrackingAutomationPolicy.startDecision(
        backendConnected: true,
        isRunning: false,
        repoURL: repoURL
    ) == .start(repoURL.standardizedFileURL),
    "current repo should be valid"
)
expect(
    DevTrackingAutomationPolicy.startDecision(
        backendConnected: false,
        isRunning: false,
        repoURL: repoURL
    ) == .blocked("Dev Tracking: backend 연결이 없어 시작하지 않음"),
    "backend should be required"
)
expect(
    DevTrackingAutomationPolicy.startDecision(
        backendConnected: true,
        isRunning: true,
        repoURL: repoURL
    ) == .alreadyRunning,
    "duplicate start should be blocked"
)

let nonGitURL = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["NON_GIT_REPO"]!
)
expect(
    DevTrackingAutomationPolicy.startDecision(
        backendConnected: true,
        isRunning: false,
        repoURL: nonGitURL
    ) == .blocked("Dev Tracking 오류: repo 경로에 .git이 없습니다."),
    "non-git directory should be blocked"
)
expect(
    DevTrackingAutomationPolicy.startDecision(
        backendConnected: true,
        isRunning: false,
        repoURL: URL(fileURLWithPath: "/Users/a/Desktop/mwoham")
    ) == .blocked("Dev Tracking 오류: Desktop 경로는 감시 대상으로 사용할 수 없습니다."),
    "Desktop path should be blocked"
)

print("Dev Tracking automation policy tests passed")
SWIFT

mkdir -p "$WORK_DIR/non-git"
CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache" swiftc \
    "$WORK_DIR/main.swift" \
    "$SOURCE_FILE" \
    -o "$WORK_DIR/harness"
MWOHAM_REPO_ROOT="$ROOT_DIR" NON_GIT_REPO="$WORK_DIR/non-git" "$WORK_DIR/harness"
