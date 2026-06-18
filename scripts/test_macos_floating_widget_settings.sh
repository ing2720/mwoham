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
