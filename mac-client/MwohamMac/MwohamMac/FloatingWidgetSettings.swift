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

    var color: Color {
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
}
