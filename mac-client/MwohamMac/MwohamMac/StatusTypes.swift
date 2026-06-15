//
//  StatusTypes.swift
//  MwohamMac
//

import Foundation

protocol StatusPresentable {
    var label: String { get }
    var isRunning: Bool { get }
    var isError: Bool { get }
    var systemImage: String { get }
}

enum RecordingState: Equatable, StatusPresentable {
    case active
    case paused
    case stopped
    case unknown

    init(apiValue: String) {
        switch apiValue {
        case "active":
            self = .active
        case "paused":
            self = .paused
        case "stopped":
            self = .stopped
        default:
            self = .unknown
        }
    }

    var label: String {
        switch self {
        case .active:
            return "기록중"
        case .paused:
            return "일시정지"
        case .stopped:
            return "정지"
        case .unknown:
            return "알 수 없음"
        }
    }

    var isActive: Bool {
        self == .active
    }

    var isRunning: Bool {
        self == .active || self == .paused
    }

    var isError: Bool {
        self == .unknown
    }

    var systemImage: String {
        switch self {
        case .active:
            return "record.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .stopped:
            return "stop.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }
}

enum ConnectionState: Equatable, StatusPresentable {
    case checking
    case connected
    case disconnected

    var label: String {
        switch self {
        case .checking:
            return "연결 확인 중"
        case .connected:
            return "백엔드 연결됨"
        case .disconnected:
            return "백엔드 연결 실패"
        }
    }

    var isActive: Bool {
        self == .connected
    }

    var isRunning: Bool {
        isActive
    }

    var isError: Bool {
        self == .disconnected
    }

    var systemImage: String {
        switch self {
        case .checking:
            return "arrow.trianglehead.2.clockwise"
        case .connected:
            return "checkmark.circle.fill"
        case .disconnected:
            return "xmark.circle.fill"
        }
    }
}

enum MeetingTranscriptionState: Equatable, StatusPresentable {
    case idle
    case checkingPermission
    case starting
    case running(String)
    case processing(String)
    case stopping
    case stopped(String)
    case error(String)

    init(statusText: String) {
        let normalized = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("실패") || normalized.contains("오류") {
            self = .error(normalized)
        } else if normalized.contains("권한 확인") {
            self = .checkingPermission
        } else if normalized.contains("시작 중") {
            self = .starting
        } else if normalized.contains("종료 중") {
            self = .stopping
        } else if normalized.contains("처리 중") || normalized.contains("저장 중") {
            self = .processing(normalized)
        } else if normalized.contains("전사 중") {
            self = .running(normalized)
        } else if normalized.contains("종료") || normalized.contains("저장됨") {
            self = .stopped(normalized)
        } else {
            self = .idle
        }
    }

    var label: String {
        switch self {
        case .idle:
            return "회의 전사 대기 중"
        case .checkingPermission:
            return "권한 확인 중"
        case .starting:
            return "회의 전사 시작 중"
        case let .running(label),
             let .processing(label),
             let .stopped(label),
             let .error(label):
            return label
        case .stopping:
            return "회의 전사 종료 중"
        }
    }

    var isRunning: Bool {
        switch self {
        case .starting, .running, .processing, .stopping:
            return true
        default:
            return false
        }
    }

    var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }

    var systemImage: String {
        switch self {
        case .running:
            return "waveform.circle.fill"
        case .checkingPermission, .starting, .processing, .stopping:
            return "ellipsis.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        case .idle, .stopped:
            return "waveform.circle"
        }
    }
}

enum STTEngineState: Equatable, StatusPresentable {
    case appleSpeech
    case localWhisper(String)
    case appleSpeechFallback
    case unavailable
    case other(String)

    init(description: String) {
        let normalized = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.localizedCaseInsensitiveContains("fallback") {
            self = .appleSpeechFallback
        } else if normalized.localizedCaseInsensitiveContains("whisper") {
            self = .localWhisper(normalized)
        } else if normalized.localizedCaseInsensitiveContains("apple speech") {
            self = .appleSpeech
        } else if normalized.isEmpty || normalized == "-" {
            self = .unavailable
        } else {
            self = .other(normalized)
        }
    }

    var label: String {
        switch self {
        case .appleSpeech:
            return "Apple Speech"
        case let .localWhisper(label), let .other(label):
            return label
        case .appleSpeechFallback:
            return "Apple Speech (fallback)"
        case .unavailable:
            return "사용할 수 없음"
        }
    }

    var isActive: Bool {
        self != .unavailable
    }

    var isRunning: Bool {
        isActive
    }

    var isError: Bool {
        self == .unavailable
    }

    var systemImage: String {
        switch self {
        case .localWhisper:
            return "cpu"
        case .appleSpeech, .appleSpeechFallback:
            return "waveform"
        case .unavailable:
            return "exclamationmark.triangle"
        case .other:
            return "waveform.badge.magnifyingglass"
        }
    }
}

enum CollectorState: Equatable, StatusPresentable {
    case idle(String)
    case running(String)
    case error(String)

    init(statusText: String) {
        let normalized = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("오류") || normalized.contains("실패") {
            self = .error(normalized)
        } else if normalized.contains("추적 중")
            || normalized.contains("감시 중")
            || normalized.contains("감시 시작")
            || normalized.contains("변경 없음")
            || normalized.contains("변경 감지")
            || normalized.contains("수집 중")
            || normalized.contains("저장됨") {
            self = .running(normalized)
        } else {
            self = .idle(normalized)
        }
    }

    var label: String {
        switch self {
        case let .idle(label), let .running(label), let .error(label):
            return label
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }

    var systemImage: String {
        switch self {
        case .idle:
            return "circle"
        case .running:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}
