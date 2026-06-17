#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/mac-client/MwohamMac/MwohamMac"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mwoham-widget-responsive.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/FloatingWidgetResponsiveHarness.swift" <<'SWIFT'
import Foundation

final class FakePresentationProvider: AppStatusPresentationProviding {
    var connectionState: ConnectionState = .connected
    var backendAddressText = "http://127.0.0.1:8765"
    var recordingState: RecordingState = .active
    var recordingElapsedTime = "01:02:03"
    var activeWindowTrackingState =
        CollectorState.running("활성 창 감시 중")
    var ocrState = CollectorState.running("OCR 수집 중")
    var devTrackingState = CollectorState.running("Dev Tracking: 추적 중")
    var isDevTrackingRunning = true
    var shortDevTrackingStatus = "Dev 추적 중"
    var currentApp = "Xcode"
    var currentWindow =
        "A very long window title that should be truncated in compact mode for readability"
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
    typealias LayoutMode = MenuBarFloatingPresentation.FloatingWidgetLayoutMode

    expect(
        LayoutMode.mode(width: 250, height: 360) == .compact,
        "narrow width should select compact"
    )
    expect(
        LayoutMode.mode(width: 330, height: 360) == .normal,
        "default widget size should select normal"
    )
    expect(
        LayoutMode.mode(width: 390, height: 360) == .expanded,
        "wide widget should select expanded"
    )
    expect(
        LayoutMode.mode(width: 330, height: 430) == .expanded,
        "tall widget should select expanded"
    )

    let provider = FakePresentationProvider()
    let presentation = MenuBarFloatingPresentation(
        provider: provider,
        isFloatingWidgetVisible: true
    )

    expect(
        presentation.compactCurrentActivityText.count <= 42,
        "compact current activity should be truncated"
    )
    expect(
        presentation.compactRecordingSummary == "기록중 · 01:02:03",
        "compact recording summary should combine state and elapsed time"
    )
    expect(
        !presentation.shouldShowCurrentWindowInCompact,
        "compact mode should not show full current window row"
    )
    expect(
        presentation.shouldShowDevTrackingInCompact,
        "compact mode can show short Dev Tracking badge"
    )
    expect(
        !presentation.shouldShowMeetingModeInCompact,
        "compact mode should hide meeting mode controls"
    )
    expect(
        presentation.devTrackingDisplayText == "Dev Tracking:기록중",
        "Dev Tracking compact badge text should be single display value"
    )

    provider.isPrivateAppActive = true
    let privatePresentation = MenuBarFloatingPresentation(
        provider: provider,
        isFloatingWidgetVisible: true
    )
    expect(
        privatePresentation.compactCurrentActivityText == "비공개 앱",
        "compact mode should preserve private app signal"
    )

    print("FloatingWidget responsive harness passed")
}

@main
enum FloatingWidgetResponsiveHarness {
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
    "$WORK_DIR/FloatingWidgetResponsiveHarness.swift" \
    "$APP_DIR/StatusTypes.swift" \
    "$APP_DIR/MenuBarFloatingPresentation.swift" \
    -o "$WORK_DIR/floating_widget_responsive_harness"

"$WORK_DIR/floating_widget_responsive_harness"
