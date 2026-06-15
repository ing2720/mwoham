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

let repoRoot = ProcessInfo.processInfo.environment["MWOHAM_REPO_ROOT"]!
let repoURL = URL(fileURLWithPath: repoRoot)

expect(
    DevTrackingAutomationPolicy.action(for: .started) == .start,
    "recording start should start Dev Tracking"
)
expect(
    DevTrackingAutomationPolicy.action(for: .stopped) == .stop,
    "recording stop should stop Dev Tracking"
)
expect(
    DevTrackingAutomationPolicy.action(for: .paused) == .none,
    "recording pause should keep Dev Tracking running"
)
expect(
    DevTrackingAutomationPolicy.action(for: .resumed) == .none,
    "recording resume should not start a duplicate watcher"
)
expect(
    DevTrackingAutomationPolicy.startDecision(
        backendConnected: true,
        isRunning: false,
        repoURL: repoURL
    ) == .start(repoURL.standardizedFileURL),
    "the current mwoham repo should pass path and .git validation"
)
expect(
    DevTrackingAutomationPolicy.startDecision(
        backendConnected: false,
        isRunning: false,
        repoURL: repoURL
    ) == .blocked("Dev Tracking: backend 연결이 없어 시작하지 않음"),
    "a disconnected backend should block automatic start"
)
expect(
    DevTrackingAutomationPolicy.startDecision(
        backendConnected: true,
        isRunning: true,
        repoURL: repoURL
    ) == .alreadyRunning,
    "an existing watcher should not start twice"
)

let missingRepoURL = URL(fileURLWithPath: "/private/tmp/mwoham-missing-repo")
expect(
    DevTrackingAutomationPolicy.startDecision(
        backendConnected: true,
        isRunning: false,
        repoURL: missingRepoURL
    ) == .blocked("Dev Tracking 오류: 추적 repo 경로를 찾을 수 없습니다."),
    "a missing repo should be rejected"
)

let nonGitRepoURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NON_GIT_REPO"]!)
expect(
    DevTrackingAutomationPolicy.startDecision(
        backendConnected: true,
        isRunning: false,
        repoURL: nonGitRepoURL
    ) == .blocked("Dev Tracking 오류: repo 경로에 .git이 없습니다."),
    "a directory without .git should be rejected"
)

let desktopURL = URL(fileURLWithPath: "/Users/a/Desktop/mwoham")
expect(
    DevTrackingAutomationPolicy.startDecision(
        backendConnected: true,
        isRunning: false,
        repoURL: desktopURL
    ) == .blocked("Dev Tracking 오류: Desktop 경로는 감시 대상으로 사용할 수 없습니다."),
    "Desktop paths should be rejected before filesystem access"
)

print("Dev Tracking automation policy tests passed")
SWIFT

mkdir -p "$WORK_DIR/non-git-repo"
CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache" swiftc \
    "$WORK_DIR/main.swift" \
    "$SOURCE_FILE" \
    -o "$WORK_DIR/harness"
MWOHAM_REPO_ROOT="$ROOT_DIR" NON_GIT_REPO="$WORK_DIR/non-git-repo" "$WORK_DIR/harness"
