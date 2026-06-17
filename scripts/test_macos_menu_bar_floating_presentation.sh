#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/mac-client/MwohamMac/MwohamMac"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mwoham-menu-widget.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/MenuBarFloatingPresentationHarness.swift" <<'SWIFT'
import Foundation

final class FakePresentationProvider: AppStatusPresentationProviding {
    var connectionState: ConnectionState = .connected
    var backendAddressText = "http://127.0.0.1:8765"
    var recordingState: RecordingState = .stopped
    var recordingElapsedTime = "00:00:12"
    var activeWindowTrackingState =
        CollectorState.running("활성 창 감시 중")
    var ocrState = CollectorState.idle("OCR 대기 중")
    var devTrackingState = CollectorState.running("Dev Tracking: 추적 중")
    var isDevTrackingRunning = true
    var shortDevTrackingStatus = "Dev 추적 중"
    var currentApp = "Xcode"
    var currentWindow = "MwohamMac - MenuBarStatusView.swift"
    var isPrivateAppActive = false
    var isLoading = false
    var meetingModeState = MeetingTranscriptionState.idle
    var canStartMeetingMode = true
    var canStopMeetingMode = false
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

@MainActor
func runHarness() {
    let provider = FakePresentationProvider()

    let visible = MenuBarFloatingPresentation(
        provider: provider,
        isFloatingWidgetVisible: true
    )
    expect(visible.backendDetail == nil, "connected backend should not show detail")
    expect(visible.menuBarIconName == "circle", "stopped recording should use idle icon")
    expect(visible.recordingElapsedTimeText == "00:00:12", "elapsed time should be shared")
    expect(visible.currentAppText == "Xcode", "current app should be shared")
    expect(visible.quickActions.floatingWidgetTitle == "플로팅 위젯 닫기", "visible widget should close")
    expect(visible.quickActions.canRefresh, "refresh should be enabled when not loading")
    expect(visible.controlActions.recordingStartLabel == "기록 시작", "recording start label should be stable")
    expect(!visible.controlActions.isRecordingStartDisabled, "stopped recording can start")
    expect(visible.controlActions.isRecordingStopDisabled, "stopped recording cannot stop")
    expect(visible.controlActions.devTrackingToggleLabel == "Dev Tracking 종료", "running dev tracking should stop")
    expect(visible.controlActions.meetingModeToggleLabel == "회의모드 시작", "idle meeting should start")
    expect(visible.devTrackingBadgeText == "Dev Tracking:기록중", "running dev tracking badge should be explicit")
    expect(visible.devTrackingDisplayText == "Dev Tracking:기록중", "running dev tracking should have one display value")
    expect(
        visible.collapsedDetailText == "00:00:12 · Dev 추적 중",
        "collapsed text should share elapsed time and Dev Tracking label"
    )

    let hidden = MenuBarFloatingPresentation(
        provider: provider,
        isFloatingWidgetVisible: false
    )
    expect(hidden.quickActions.floatingWidgetTitle == "플로팅 위젯 열기", "hidden widget should open")

    provider.connectionState = .disconnected
    let disconnected = MenuBarFloatingPresentation(
        provider: provider,
        isFloatingWidgetVisible: false
    )
    expect(disconnected.menuBarIconName == "exclamationmark.circle.fill", "backend error should use error icon")
    expect(disconnected.backendDetail == "로컬 서버 확인: http://127.0.0.1:8765", "backend error detail should be shared")
    expect(disconnected.collapsedDetailText == "연결 실패", "collapsed error text should be shared")

    provider.connectionState = .connected
    provider.recordingState = .active
    let recording = MenuBarFloatingPresentation(
        provider: provider,
        isFloatingWidgetVisible: false
    )
    expect(recording.menuBarIconName == "record.circle.fill", "active recording should use filled icon")
    expect(recording.controlActions.isRecordingStartDisabled, "active recording cannot start again")
    expect(!recording.controlActions.isRecordingPauseResumeDisabled, "active recording can pause")
    expect(!recording.controlActions.isRecordingStopDisabled, "active recording can stop")

    provider.recordingState = .paused
    let paused = MenuBarFloatingPresentation(
        provider: provider,
        isFloatingWidgetVisible: false
    )
    expect(paused.menuBarIconName == "pause.circle.fill", "paused recording should use pause icon")
    expect(paused.controlActions.recordingPauseResumeLabel == "기록 재개", "paused recording should resume")

    provider.recordingState = .stopped
    provider.meetingModeState = .running("회의 전체 전사 중")
    provider.canStartMeetingMode = false
    provider.canStopMeetingMode = true
    let meetingRunning = MenuBarFloatingPresentation(
        provider: provider,
        isFloatingWidgetVisible: false
    )
    expect(meetingRunning.controlActions.meetingModeToggleLabel == "회의모드 종료", "running meeting should stop")
    expect(!meetingRunning.controlActions.isMeetingModeToggleDisabled, "running meeting can stop")
    expect(meetingRunning.menuBarIconName == "waveform.circle.fill", "running meeting should use waveform icon")

    provider.meetingModeState = .idle
    provider.canStartMeetingMode = true
    provider.canStopMeetingMode = false
    provider.isPrivateAppActive = true
    let privateApp = MenuBarFloatingPresentation(
        provider: provider,
        isFloatingWidgetVisible: false
    )
    expect(privateApp.collapsedDetailText == "비공개", "private app collapsed text should be shared")

    provider.isPrivateAppActive = false
    provider.devTrackingState = CollectorState.idle("Dev Tracking: 종료됨")
    provider.isDevTrackingRunning = false
    let devStopped = MenuBarFloatingPresentation(
        provider: provider,
        isFloatingWidgetVisible: false
    )
    expect(devStopped.devTrackingBadgeText == "Dev Tracking:기록중지", "stopped dev tracking badge should be explicit")
    expect(devStopped.controlActions.devTrackingToggleLabel == "Dev Tracking 시작", "stopped dev tracking should start")

    provider.devTrackingState = CollectorState(statusText: "Dev Tracking 오류: watcher 종료 코드 143")
    let devError = MenuBarFloatingPresentation(
        provider: provider,
        isFloatingWidgetVisible: false
    )
    expect(devError.devTrackingBadgeText == "Dev Tracking:error", "dev tracking error badge should be explicit")
    expect(devError.devTrackingDisplayText == "Dev Tracking:error143", "dev tracking error display should keep error code")

    provider.devTrackingState = CollectorState.idle("Dev Tracking: 종료됨")
    provider.currentApp = "-"
    provider.currentWindow = ""
    provider.recordingElapsedTime = ""
    provider.isLoading = true
    let fallback = MenuBarFloatingPresentation(
        provider: provider,
        isFloatingWidgetVisible: false
    )
    expect(fallback.currentAppText == "현재 앱 없음", "empty app should use fallback")
    expect(fallback.currentWindowText == "현재 창 없음", "empty window should use fallback")
    expect(fallback.recordingElapsedTimeText == "00:00:00", "empty elapsed should use fallback")
    expect(!fallback.quickActions.canRefresh, "loading should disable refresh")

    print("MenuBarFloatingPresentation harness passed")
}

@main
enum MenuBarFloatingPresentationHarness {
    static func main() async {
        await MainActor.run {
            runHarness()
        }
    }
}
SWIFT

swiftc \
    -D MWOHAM_PRESENTATION_HARNESS \
    -module-cache-path "$WORK_DIR/module-cache" \
    "$WORK_DIR/MenuBarFloatingPresentationHarness.swift" \
    "$APP_DIR/StatusTypes.swift" \
    "$APP_DIR/MenuBarFloatingPresentation.swift" \
    -o "$WORK_DIR/menu_bar_floating_presentation_harness"

"$WORK_DIR/menu_bar_floating_presentation_harness"
