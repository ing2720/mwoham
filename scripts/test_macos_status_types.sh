#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/StatusTypes.swift"
WORK_DIR="$(mktemp -d /private/tmp/mwoham-status-types.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("failed: \(message)\n", stderr)
        exit(1)
    }
}

expect(RecordingState(apiValue: "active") == .active, "active recording state")
expect(RecordingState(apiValue: "paused") == .paused, "paused recording state")
expect(RecordingState(apiValue: "stopped") == .stopped, "stopped recording state")
expect(RecordingState(apiValue: "invalid").isError, "unknown recording state")
expect(RecordingState.active.label == "기록중", "recording label")
expect(RecordingState.paused.isRunning, "paused session remains running")

expect(ConnectionState.connected.isActive, "connected state")
expect(ConnectionState.disconnected.isError, "disconnected state")
expect(ConnectionState.connected.label == "백엔드 연결됨", "connection label")

let transcriptionError = MeetingTranscriptionState(
    statusText: "회의 전사 시작 실패: 권한 없음"
)
expect(transcriptionError.isError, "meeting transcription error")
expect(
    MeetingTranscriptionState(statusText: "회의 전체 전사 중").isRunning,
    "meeting transcription running state"
)

expect(
    STTEngineState(description: "Apple Speech") == .appleSpeech,
    "Apple Speech engine"
)
expect(
    STTEngineState(description: "Apple Speech (fallback)") == .appleSpeechFallback,
    "fallback engine"
)
expect(
    STTEngineState(description: "Local Whisper (microphone)").label
        == "Local Whisper (microphone)",
    "Whisper engine detail"
)

let collectorError = CollectorState(statusText: "Dev Tracking 오류: Git repo가 아닙니다.")
expect(collectorError.isError, "collector error")
expect(
    CollectorState(statusText: "Dev Tracking: 감시 중").isRunning,
    "collector running state"
)

print("macOS status type tests passed")
SWIFT

CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache" swiftc \
    "$WORK_DIR/main.swift" \
    "$SOURCE_FILE" \
    -o "$WORK_DIR/harness"
"$WORK_DIR/harness"
