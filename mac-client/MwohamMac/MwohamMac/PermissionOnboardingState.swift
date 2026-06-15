//
//  PermissionOnboardingState.swift
//  MwohamMac
//

import Foundation

enum PermissionRequirement: String {
    case required = "필수"
    case recommended = "권장"
    case optional = "선택"
}

enum PermissionSetupStatus: Equatable, StatusPresentable {
    case allowed
    case checkRequired
    case limited
    case setupRequired

    var label: String {
        switch self {
        case .allowed:
            return "허용됨"
        case .checkRequired:
            return "확인 필요"
        case .limited:
            return "제한됨"
        case .setupRequired:
            return "설정 필요"
        }
    }

    var isRunning: Bool {
        self == .allowed
    }

    var isError: Bool {
        self == .setupRequired
    }

    var systemImage: String {
        switch self {
        case .allowed:
            return "checkmark.circle.fill"
        case .checkRequired:
            return "questionmark.circle"
        case .limited:
            return "exclamationmark.triangle.fill"
        case .setupRequired:
            return "gearshape.badge.questionmark"
        }
    }
}

enum PermissionOptionStatus: Equatable, StatusPresentable {
    case enabled
    case disabled

    var label: String {
        self == .enabled ? "켜짐" : "꺼짐"
    }

    var isRunning: Bool {
        self == .enabled
    }

    var isError: Bool {
        false
    }

    var systemImage: String {
        self == .enabled ? "checkmark.circle.fill" : "circle"
    }
}

struct PermissionOnboardingSnapshot: Equatable {
    let microphoneAuthorized: Bool
    let speechRecognitionAuthorized: Bool
    let screenRecordingAuthorized: Bool
    let accessibilityAuthorized: Bool
    let localWhisperAvailable: Bool
    let backendConnected: Bool
    let debugAudioEnabled: Bool
    let devTrackingEnabled: Bool
    let hasActiveWindowSignal: Bool

    var canStart: Bool {
        microphoneAuthorized
            && (speechRecognitionAuthorized || localWhisperAvailable)
            && backendConnected
    }

    var hasRecommendedWarnings: Bool {
        !screenRecordingAuthorized || !accessibilityAuthorized
    }

    var microphoneStatus: PermissionSetupStatus {
        microphoneAuthorized ? .allowed : .setupRequired
    }

    var speechRecognitionStatus: PermissionSetupStatus {
        if speechRecognitionAuthorized {
            return .allowed
        }
        return localWhisperAvailable ? .limited : .setupRequired
    }

    var screenRecordingStatus: PermissionSetupStatus {
        screenRecordingAuthorized ? .allowed : .checkRequired
    }

    var accessibilityStatus: PermissionSetupStatus {
        if accessibilityAuthorized {
            return .allowed
        }
        return hasActiveWindowSignal ? .limited : .checkRequired
    }

    var debugAudioStatus: PermissionOptionStatus {
        debugAudioEnabled ? .enabled : .disabled
    }

    var devTrackingStatus: PermissionOptionStatus {
        devTrackingEnabled ? .enabled : .disabled
    }
}
