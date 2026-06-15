#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_TYPES="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/StatusTypes.swift"
STT_UI_STATE="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/STTUIState.swift"
MEETING_AUDIO_SOURCE="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/MeetingAudioSource.swift"
WORK_DIR="$(mktemp -d /private/tmp/mwoham-stt-ui-state.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

printf '#!/bin/sh\nexit 0\n' > "$WORK_DIR/whisper-cli"
chmod +x "$WORK_DIR/whisper-cli"
printf 'model-data' > "$WORK_DIR/model.bin"

cat > "$WORK_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("failed: \(message)\n", stderr)
        exit(1)
    }
}

let workDirectory = ProcessInfo.processInfo.environment["WORK_DIR"]!
let available = WhisperSettingsInspection.inspect(
    binaryPath: "\(workDirectory)/whisper-cli",
    modelPath: "\(workDirectory)/model.bin"
)
expect(available.binaryExists, "binary exists")
expect(available.binaryIsExecutable, "binary executable")
expect(available.modelExists, "model exists")
expect(available.modelFileSizeBytes == 10, "model size")
expect(available.state == .localWhisperAvailable, "Whisper available")

let missingModel = WhisperSettingsInspection.inspect(
    binaryPath: "\(workDirectory)/whisper-cli",
    modelPath: "\(workDirectory)/missing.bin"
)
expect(
    missingModel.state
        == .configurationRequired("Whisper 모델 파일을 찾을 수 없습니다."),
    "missing model state"
)

expect(
    STTDisplayState.appleSpeechFallback.label
        == "Apple Speech fallback 사용 중",
    "fallback Korean label"
)
expect(STTDisplayState.processing.isRunning, "processing state")
expect(
    STTRejectReasonLabel.label(for: "subtitle_ad_hallucination")
        == "자막/광고성 환각",
    "reject reason label"
)

let summary = STTResultSummary(
    didComplete: true,
    succeeded: true,
    usedFallback: false,
    processingSeconds: 1.25,
    sourceDiagnostics: [
        STTSourceDiagnostic(
            id: "microphone",
            sourceLabel: "마이크",
            wasAttempted: true,
            wasIncluded: true,
            failureReason: nil,
            processingSeconds: 1.25,
            chunkCount: 3,
            acceptedChunkCount: 2,
            rejectedChunkCount: 1,
            rejectReasons: ["dot_heavy": 1],
            debugExportPath: nil
        ),
    ]
)
expect(summary.chunkSummaryText == "채택 2개 / 제외 1개", "chunk summary")
expect(summary.resultText == "전사 저장 성공", "result summary")

print("macOS STT UI state tests passed")
SWIFT

CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache" swiftc \
    "$WORK_DIR/main.swift" \
    "$STATUS_TYPES" \
    "$MEETING_AUDIO_SOURCE" \
    "$STT_UI_STATE" \
    -o "$WORK_DIR/harness"
WORK_DIR="$WORK_DIR" "$WORK_DIR/harness"
