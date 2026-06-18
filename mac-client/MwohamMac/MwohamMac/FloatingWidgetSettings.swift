//
//  FloatingWidgetSettings.swift
//  MwohamMac
//

import SwiftUI

struct FloatingWidgetSettings: Codable, Equatable {
    static let opacityRange: ClosedRange<Double> = 0.6...1.0
    static let defaults = FloatingWidgetSettings()

    var opacity: Double = 1.0
    var accentColor: FloatingWidgetAccentColor = .system

    var showsCurrentApp: Bool = true
    var showsCurrentWindow: Bool = true
    var showsOCRStatus: Bool = true
    var showsDevTrackingStatus: Bool = true
    var showsElapsedTime: Bool = true

    var showsOpenMainWindowAction: Bool = true
    var showsOpenDashboardAction: Bool = true
    var showsDevTrackingAction: Bool = true
    var showsMeetingModeAction: Bool = true

    var normalized: FloatingWidgetSettings {
        var copy = self
        copy.opacity = Self.clampedOpacity(copy.opacity)
        return copy
    }

    static func clampedOpacity(_ opacity: Double) -> Double {
        min(max(opacity, opacityRange.lowerBound), opacityRange.upperBound)
    }
}

enum FloatingWidgetAccentColor: String, CaseIterable, Codable, Equatable, Identifiable {
    case system
    case green
    case blue
    case purple
    case orange
    case gray

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .system:
            return "시스템"
        case .green:
            return "초록"
        case .blue:
            return "파랑"
        case .purple:
            return "보라"
        case .orange:
            return "주황"
        case .gray:
            return "회색"
        }
    }

    var accentColor: Color {
        switch self {
        case .system:
            return .accentColor
        case .green:
            return .green
        case .blue:
            return .blue
        case .purple:
            return .purple
        case .orange:
            return .orange
        case .gray:
            return .gray
        }
    }

    var color: Color {
        accentColor
    }

    var textAccentColor: Color {
        switch self {
        case .gray:
            return .secondary
        default:
            return accentColor
        }
    }

    var subtleBackgroundColor: Color {
        accentColor.opacity(self == .gray ? 0.08 : 0.10)
    }

    var borderColor: Color {
        accentColor.opacity(self == .gray ? 0.18 : 0.24)
    }
}

enum FloatingWidgetSemanticPalette {
    static let devTrackingRunning: Color = .green
    static let devTrackingStopping: Color = .orange
    static let devTrackingStopped: Color = .secondary
    static let devTrackingError: Color = .red
}

struct FloatingWidgetLayoutAvailability: Equatable {
    var showsCompactActivity: Bool = false
    var showsCurrentApp: Bool = false
    var showsCurrentWindow: Bool = false
    var showsOCRStatus: Bool = false
    var showsDevTrackingRow: Bool = false
    var showsDevTrackingBadge: Bool = false
    var showsElapsedTime: Bool = false

    var showsOpenMainWindowAction: Bool = false
    var showsOpenDashboardAction: Bool = false
    var showsDevTrackingAction: Bool = false
    var showsMeetingModeAction: Bool = false
    var usesSingleColumnActions: Bool = false
}

struct FloatingWidgetActionAvailability: Equatable {
    var canOpenMainWindow: Bool = true
    var canOpenDashboard: Bool = true
    var canToggleDevTracking: Bool = true
    var canToggleMeetingMode: Bool = true
}

struct FloatingWidgetDisplayPolicy: Equatable {
    let showsCompactActivity: Bool
    let showsCurrentApp: Bool
    let showsCurrentWindow: Bool
    let showsOCRStatus: Bool
    let showsDevTrackingRow: Bool
    let showsDevTrackingBadge: Bool
    let showsElapsedTime: Bool

    let showsOpenMainWindowAction: Bool
    let showsOpenDashboardAction: Bool
    let showsDevTrackingAction: Bool
    let showsMeetingModeAction: Bool
    let usesSingleColumnActions: Bool

    var showsAnyQuickAction: Bool {
        showsOpenMainWindowAction
            || showsOpenDashboardAction
            || showsDevTrackingAction
            || showsMeetingModeAction
    }

    var showsAnySecondaryAction: Bool {
        showsDevTrackingAction || showsMeetingModeAction
    }

    var showsAnyOpenAction: Bool {
        showsOpenMainWindowAction || showsOpenDashboardAction
    }

    init(
        settings: FloatingWidgetSettings,
        layout: FloatingWidgetLayoutAvailability,
        actions: FloatingWidgetActionAvailability = FloatingWidgetActionAvailability()
    ) {
        showsCompactActivity =
            layout.showsCompactActivity
            && settings.showsCurrentApp
            && settings.showsCurrentWindow
        showsCurrentApp = settings.showsCurrentApp && layout.showsCurrentApp
        showsCurrentWindow =
            settings.showsCurrentWindow && layout.showsCurrentWindow
        showsOCRStatus = settings.showsOCRStatus && layout.showsOCRStatus
        showsDevTrackingRow =
            settings.showsDevTrackingStatus && layout.showsDevTrackingRow
        showsDevTrackingBadge =
            settings.showsDevTrackingStatus
            && !layout.showsDevTrackingRow
            && layout.showsDevTrackingBadge
        showsElapsedTime = settings.showsElapsedTime && layout.showsElapsedTime

        showsOpenMainWindowAction =
            settings.showsOpenMainWindowAction
            && layout.showsOpenMainWindowAction
            && actions.canOpenMainWindow
        showsOpenDashboardAction =
            settings.showsOpenDashboardAction
            && layout.showsOpenDashboardAction
            && actions.canOpenDashboard
        showsDevTrackingAction =
            settings.showsDevTrackingAction
            && layout.showsDevTrackingAction
            && actions.canToggleDevTracking
        showsMeetingModeAction =
            settings.showsMeetingModeAction
            && layout.showsMeetingModeAction
            && actions.canToggleMeetingMode
        usesSingleColumnActions = layout.usesSingleColumnActions
    }
}
