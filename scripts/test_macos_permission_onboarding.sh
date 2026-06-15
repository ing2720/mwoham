#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_TYPES="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/StatusTypes.swift"
ONBOARDING_STATE="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/PermissionOnboardingState.swift"
WORK_DIR="$(mktemp -d /private/tmp/mwoham-permission-onboarding.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("failed: \(message)\n", stderr)
        exit(1)
    }
}

let readyWithSpeech = PermissionOnboardingSnapshot(
    microphoneAuthorized: true,
    speechRecognitionAuthorized: true,
    screenRecordingAuthorized: false,
    accessibilityAuthorized: false,
    localWhisperAvailable: false,
    backendConnected: true,
    debugAudioEnabled: false,
    devTrackingEnabled: false,
    hasActiveWindowSignal: true
)
expect(readyWithSpeech.canStart, "microphone and speech permissions allow start")
expect(
    readyWithSpeech.hasRecommendedWarnings,
    "missing recommended permissions produce a warning"
)
expect(
    readyWithSpeech.accessibilityStatus == .limited,
    "active window signal keeps accessibility non-fatal"
)
expect(
    !readyWithSpeech.accessibilityStatus.isError,
    "accessibility warning is not an error"
)

let readyWithWhisper = PermissionOnboardingSnapshot(
    microphoneAuthorized: true,
    speechRecognitionAuthorized: false,
    screenRecordingAuthorized: true,
    accessibilityAuthorized: true,
    localWhisperAvailable: true,
    backendConnected: true,
    debugAudioEnabled: true,
    devTrackingEnabled: true,
    hasActiveWindowSignal: true
)
expect(readyWithWhisper.canStart, "Local Whisper satisfies the STT requirement")
expect(
    readyWithWhisper.speechRecognitionStatus == .limited,
    "speech permission is limited when Whisper is available"
)

let missingMicrophone = PermissionOnboardingSnapshot(
    microphoneAuthorized: false,
    speechRecognitionAuthorized: true,
    screenRecordingAuthorized: true,
    accessibilityAuthorized: true,
    localWhisperAvailable: true,
    backendConnected: true,
    debugAudioEnabled: false,
    devTrackingEnabled: false,
    hasActiveWindowSignal: false
)
expect(!missingMicrophone.canStart, "microphone is required")
expect(
    missingMicrophone.microphoneStatus == .setupRequired,
    "missing microphone requires setup"
)

let missingSTT = PermissionOnboardingSnapshot(
    microphoneAuthorized: true,
    speechRecognitionAuthorized: false,
    screenRecordingAuthorized: true,
    accessibilityAuthorized: true,
    localWhisperAvailable: false,
    backendConnected: true,
    debugAudioEnabled: false,
    devTrackingEnabled: true,
    hasActiveWindowSignal: false
)
expect(!missingSTT.canStart, "one STT engine is required")
expect(
    missingSTT.speechRecognitionStatus == .setupRequired,
    "missing speech permission requires setup"
)

let missingBackend = PermissionOnboardingSnapshot(
    microphoneAuthorized: true,
    speechRecognitionAuthorized: true,
    screenRecordingAuthorized: true,
    accessibilityAuthorized: true,
    localWhisperAvailable: true,
    backendConnected: false,
    debugAudioEnabled: false,
    devTrackingEnabled: false,
    hasActiveWindowSignal: true
)
expect(!missingBackend.canStart, "backend connection remains required")

expect(readyWithSpeech.debugAudioStatus == .disabled, "debug audio defaults off")
expect(
    readyWithSpeech.devTrackingStatus == .disabled,
    "Dev Tracking shows off state"
)
expect(missingSTT.devTrackingStatus == .enabled, "Dev Tracking shows on state")

print("macOS permission onboarding tests passed")
SWIFT

CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache" swiftc \
    "$WORK_DIR/main.swift" \
    "$STATUS_TYPES" \
    "$ONBOARDING_STATE" \
    -o "$WORK_DIR/harness"
"$WORK_DIR/harness"
