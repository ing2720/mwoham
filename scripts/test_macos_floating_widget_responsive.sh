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
        LayoutMode.mode(width: 214, height: 80) == .veryCompact,
        "minimum widget size should select veryCompact"
    )
    expect(
        LayoutMode.mode(width: 330, height: 89) == .veryCompact,
        "near-minimum height should select veryCompact"
    )
    expect(
        LayoutMode.mode(width: 330, height: 220) == .compact,
        "usable short widget should keep compact layout instead of collapsing too early"
    )
    expect(
        LayoutMode.mode(width: 290, height: 260) == .compact,
        "narrow compact widget should select compact"
    )
    expect(
        LayoutMode.mode(width: 330, height: 279) == .compact,
        "widget should stay compact just below the 280pt adaptive threshold"
    )
    expect(
        LayoutMode.mode(width: 330, height: 280) == .regular,
        "widget should start regular responsive layout at 280pt height"
    )
    expect(
        LayoutMode.mode(width: 330, height: 300) == .regular,
        "medium resized widget should stay regular after the 280pt threshold"
    )
    expect(
        LayoutMode.mode(width: 330, height: 360) == .regular,
        "default widget size should select regular"
    )
    expect(
        LayoutMode.mode(width: 330, height: 330) == .regular,
        "default polished widget size should stay regular"
    )
    expect(
        LayoutMode.mode(width: 390, height: 360) == .spacious,
        "wide widget should select spacious"
    )
    expect(
        LayoutMode.mode(width: 330, height: 460) == .spacious,
        "tall widget should select spacious"
    )
    expect(
        LayoutMode.preferredCompact(width: 330, height: 360) == .compact,
        "compact preference should not force a snap size"
    )
    expect(
        LayoutMode.preferredCompact(width: 214, height: 80) == .veryCompact,
        "compact preference should still respect very small sizes"
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
        presentation.widgetVeryCompactSummary == "기록중 · 01:02:03",
        "veryCompact summary should keep only primary recording status"
    )
    expect(
        presentation.widgetCompactSummary.contains("기록중 · 01:02:03"),
        "compact summary should include primary recording status"
    )
    expect(
        presentation.compactCurrentActivityText != presentation.compactRecordingSummary,
        "compact body should be able to avoid duplicated recording summary"
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
    expect(
        !presentation.shouldShowBackendBadge(for: .veryCompact),
        "veryCompact should hide backend badge"
    )
    expect(
        !presentation.shouldShowBackendBadge(for: .compact),
        "floating widget should hide backend badge in compact"
    )
    expect(
        !presentation.shouldShowBackendBadge(for: .regular),
        "floating widget should hide backend badge in regular"
    )
    expect(
        !presentation.shouldShowSecondaryActions(for: .compact),
        "compact should hide secondary actions"
    )
    expect(
        presentation.shouldShowSecondaryActions(for: .regular),
        "regular should show secondary actions"
    )
    expect(
        !presentation.shouldUseSingleColumnActions(for: .spacious),
        "spacious should allow two-column action layout"
    )
    expect(
        !presentation.shouldUseSingleColumnActions(for: .regular),
        "regular should keep secondary actions together instead of splitting vertically"
    )
    expect(
        presentation.shouldShowCurrentWindow(for: .spacious),
        "spacious should keep current window visible"
    )
    expect(
        presentation.widgetSizeToggleLabel(for: .compact) == "표준 크기",
        "compact toggle should clearly return to standard size"
    )
    expect(
        presentation.widgetSizeToggleIconName(for: .compact) == "chevron.down",
        "compact toggle should use the original expand arrow"
    )
    expect(
        presentation.widgetSizeToggleTarget(for: .compact) == .standard,
        "compact toggle should request standard size"
    )
    expect(
        presentation.widgetSizeToggleLabel(for: .regular) == "간편보기",
        "regular toggle should offer compact view"
    )
    expect(
        presentation.widgetSizeToggleIconName(for: .regular) == "chevron.up",
        "regular toggle should use the original collapse arrow"
    )
    expect(
        presentation.widgetSizeToggleTarget(for: .regular) == .compact,
        "regular toggle should request compact size"
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
