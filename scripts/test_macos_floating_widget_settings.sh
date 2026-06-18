#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/mac-client/MwohamMac/MwohamMac"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mwoham-widget-settings.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/FloatingWidgetSettingsHarness.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

func makeDefaults(_ name: String) -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: name) else {
        fatalError("failed to create test UserDefaults")
    }
    defaults.removePersistentDomain(forName: name)
    return defaults
}

func defaultLayout() -> FloatingWidgetLayoutAvailability {
    FloatingWidgetLayoutAvailability(
        showsCompactActivity: true,
        showsCurrentApp: true,
        showsCurrentWindow: true,
        showsOCRStatus: true,
        showsDevTrackingRow: true,
        showsDevTrackingBadge: false,
        showsElapsedTime: true,
        showsOpenMainWindowAction: true,
        showsOpenDashboardAction: true,
        showsDevTrackingAction: true,
        showsMeetingModeAction: true,
        usesSingleColumnActions: true
    )
}

@main
enum FloatingWidgetSettingsHarness {
    static func main() {
        let suiteName = "mwoham.floating-widget-settings.\(UUID().uuidString)"
        let defaults = makeDefaults(suiteName)

        let store = FloatingWidgetSettingsStore(userDefaults: defaults)
        expect(store.settings.opacity == 1.0, "default opacity should be 1.0")
        expect(store.settings.accentColor == .system, "default accent color should be system")
        expect(store.settings.showsCurrentApp, "current app setting should default on")
        expect(store.settings.showsCurrentWindow, "current window setting should default on")
        expect(store.settings.showsOCRStatus, "OCR status setting should default on")
        expect(store.settings.showsDevTrackingStatus, "Dev Tracking status setting should default on")
        expect(store.settings.showsElapsedTime, "elapsed time setting should default on")
        expect(store.settings.showsOpenMainWindowAction, "main window action should default on")
        expect(store.settings.showsOpenDashboardAction, "dashboard action should default on")
        expect(store.settings.showsDevTrackingAction, "Dev Tracking action should default on")
        expect(store.settings.showsMeetingModeAction, "meeting mode action should default on")

        store.settings.opacity = 0.2
        expect(store.settings.opacity == 0.6, "opacity should clamp to lower bound")
        store.settings.opacity = 1.4
        expect(store.settings.opacity == 1.0, "opacity should clamp to upper bound")

        store.settings.opacity = 0.72
        store.settings.accentColor = .purple
        store.settings.showsCurrentApp = false
        store.settings.showsCurrentWindow = false
        store.settings.showsOCRStatus = false
        store.settings.showsDevTrackingStatus = false
        store.settings.showsElapsedTime = false
        store.settings.showsOpenMainWindowAction = false
        store.settings.showsOpenDashboardAction = false
        store.settings.showsDevTrackingAction = false
        store.settings.showsMeetingModeAction = false

        let reloaded = FloatingWidgetSettingsStore(userDefaults: defaults)
        expect(reloaded.settings.opacity == 0.72, "opacity should round-trip")
        expect(reloaded.settings.accentColor == .purple, "accent color should round-trip")
        expect(!reloaded.settings.showsCurrentApp, "current app setting should round-trip")
        expect(!reloaded.settings.showsCurrentWindow, "current window setting should round-trip")
        expect(!reloaded.settings.showsOCRStatus, "OCR status setting should round-trip")
        expect(!reloaded.settings.showsDevTrackingStatus, "Dev Tracking status setting should round-trip")
        expect(!reloaded.settings.showsElapsedTime, "elapsed time setting should round-trip")
        expect(!reloaded.settings.showsOpenMainWindowAction, "main window action should round-trip")
        expect(!reloaded.settings.showsOpenDashboardAction, "dashboard action should round-trip")
        expect(!reloaded.settings.showsDevTrackingAction, "Dev Tracking action should round-trip")
        expect(!reloaded.settings.showsMeetingModeAction, "meeting mode action should round-trip")

        reloaded.resetToDefaults()
        expect(reloaded.settings == .defaults, "reset should restore all default settings")

        let resetReloaded = FloatingWidgetSettingsStore(userDefaults: defaults)
        expect(resetReloaded.settings == .defaults, "reset defaults should persist")

        let defaultPolicy = FloatingWidgetDisplayPolicy(
            settings: .defaults,
            layout: defaultLayout()
        )
        expect(defaultPolicy.showsCompactActivity, "compact activity should show when app/window settings and layout allow it")
        expect(defaultPolicy.showsCurrentApp, "current app should show when setting and layout allow it")
        expect(defaultPolicy.showsCurrentWindow, "current window should show when setting and layout allow it")
        expect(defaultPolicy.showsOCRStatus, "OCR should show when setting and layout allow it")
        expect(defaultPolicy.showsDevTrackingRow, "Dev Tracking row should show when setting and layout allow it")
        expect(!defaultPolicy.showsDevTrackingBadge, "Dev Tracking badge should not duplicate row")
        expect(defaultPolicy.showsElapsedTime, "elapsed time should show when setting and layout allow it")
        expect(defaultPolicy.showsOpenMainWindowAction, "main window action should show when setting and layout allow it")
        expect(defaultPolicy.showsOpenDashboardAction, "dashboard action should show when setting and layout allow it")
        expect(defaultPolicy.showsDevTrackingAction, "Dev Tracking action should show when setting and layout allow it")
        expect(defaultPolicy.showsMeetingModeAction, "meeting mode action should show when setting and layout allow it")
        expect(defaultPolicy.showsAnyQuickAction, "quick action section should show when at least one action is visible")

        var displaySettings = FloatingWidgetSettings.defaults
        displaySettings.showsCurrentApp = false
        var policy = FloatingWidgetDisplayPolicy(
            settings: displaySettings,
            layout: defaultLayout()
        )
        expect(!policy.showsCurrentApp, "current app setting off should hide current app")
        expect(!policy.showsCompactActivity, "current app setting off should hide compact activity summary")

        displaySettings = .defaults
        displaySettings.showsCurrentWindow = false
        policy = FloatingWidgetDisplayPolicy(
            settings: displaySettings,
            layout: defaultLayout()
        )
        expect(!policy.showsCurrentWindow, "current window setting off should hide current window")
        expect(!policy.showsCompactActivity, "current window setting off should hide compact activity summary")

        displaySettings = .defaults
        displaySettings.showsOCRStatus = false
        policy = FloatingWidgetDisplayPolicy(
            settings: displaySettings,
            layout: defaultLayout()
        )
        expect(!policy.showsOCRStatus, "OCR setting off should hide OCR")

        displaySettings = .defaults
        displaySettings.showsDevTrackingStatus = false
        policy = FloatingWidgetDisplayPolicy(
            settings: displaySettings,
            layout: defaultLayout()
        )
        expect(!policy.showsDevTrackingRow, "Dev Tracking setting off should hide row")
        expect(!policy.showsDevTrackingBadge, "Dev Tracking setting off should hide badge")

        displaySettings = .defaults
        displaySettings.showsElapsedTime = false
        policy = FloatingWidgetDisplayPolicy(
            settings: displaySettings,
            layout: defaultLayout()
        )
        expect(!policy.showsElapsedTime, "elapsed time setting off should hide elapsed time")

        displaySettings = .defaults
        displaySettings.showsOpenMainWindowAction = false
        displaySettings.showsOpenDashboardAction = false
        displaySettings.showsDevTrackingAction = false
        displaySettings.showsMeetingModeAction = false
        policy = FloatingWidgetDisplayPolicy(
            settings: displaySettings,
            layout: defaultLayout()
        )
        expect(!policy.showsOpenMainWindowAction, "main window action setting off should hide action")
        expect(!policy.showsOpenDashboardAction, "dashboard action setting off should hide action")
        expect(!policy.showsDevTrackingAction, "Dev Tracking action setting off should hide action")
        expect(!policy.showsMeetingModeAction, "meeting mode action setting off should hide action")
        expect(!policy.showsAnyQuickAction, "all quick actions off should hide action section")
        expect(!policy.showsAnySecondaryAction, "all secondary actions off should hide secondary row")
        expect(!policy.showsAnyOpenAction, "all open actions off should hide open row")

        let compactLayout = FloatingWidgetLayoutAvailability(
            showsCompactActivity: true,
            showsCurrentApp: false,
            showsCurrentWindow: false,
            showsOCRStatus: false,
            showsDevTrackingRow: false,
            showsDevTrackingBadge: true,
            showsElapsedTime: true,
            showsOpenMainWindowAction: false,
            showsOpenDashboardAction: false,
            showsDevTrackingAction: false,
            showsMeetingModeAction: false,
            usesSingleColumnActions: true
        )
        policy = FloatingWidgetDisplayPolicy(
            settings: .defaults,
            layout: compactLayout
        )
        expect(!policy.showsCurrentApp, "layout without room should hide current app even when setting is on")
        expect(!policy.showsCurrentWindow, "layout without room should hide current window even when setting is on")
        expect(!policy.showsOCRStatus, "layout without room should hide OCR even when setting is on")
        expect(!policy.showsDevTrackingRow, "compact layout should not show full Dev Tracking row")
        expect(policy.showsDevTrackingBadge, "compact layout can show Dev Tracking badge when setting is on")
        expect(!policy.showsAnyQuickAction, "compact layout without room should hide quick action section")

        policy = FloatingWidgetDisplayPolicy(
            settings: .defaults,
            layout: defaultLayout(),
            actions: FloatingWidgetActionAvailability(
                canOpenMainWindow: true,
                canOpenDashboard: true,
                canToggleDevTracking: true,
                canToggleMeetingMode: false
            )
        )
        expect(!policy.showsMeetingModeAction, "unavailable meeting action should hide")
        expect(policy.showsDevTrackingAction, "available Dev Tracking action should remain visible")

        defaults.removePersistentDomain(forName: suiteName)
        print("FloatingWidget settings harness passed")
    }
}
SWIFT

swiftc \
    -module-cache-path "$WORK_DIR/module-cache" \
    "$WORK_DIR/FloatingWidgetSettingsHarness.swift" \
    "$APP_DIR/FloatingWidgetSettings.swift" \
    "$APP_DIR/FloatingWidgetSettingsStore.swift" \
    -o "$WORK_DIR/floating_widget_settings_harness"

"$WORK_DIR/floating_widget_settings_harness"

swiftc \
    -typecheck \
    -parse-as-library \
    -module-cache-path "$WORK_DIR/module-cache" \
    "$APP_DIR/FloatingWidgetSettings.swift" \
    "$APP_DIR/FloatingWidgetSettingsStore.swift" \
    "$APP_DIR/FloatingWidgetSettingsView.swift"
