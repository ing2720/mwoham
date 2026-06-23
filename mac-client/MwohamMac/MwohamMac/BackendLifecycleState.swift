//
//  BackendLifecycleState.swift
//  MwohamMac
//

import Foundation

enum BackendLifecycleState: Equatable, StatusPresentable {
    case checking
    case connected
    case starting
    case connectionFailed
    case portConflict
    case backendInstallationRequired
    case backendPathError
    case uvExecutionFailed
    case migrationFailed
    case stopped

    var label: String {
        switch self {
        case .checking:
            return "상태 확인 중"
        case .connected:
            return "연결됨"
        case .starting:
            return "시작 중"
        case .connectionFailed:
            return "연결 실패"
        case .portConflict:
            return "포트 충돌 의심"
        case .backendInstallationRequired:
            return "backend 설치 필요"
        case .backendPathError:
            return "backend 경로 오류"
        case .uvExecutionFailed:
            return "uv 실행 실패"
        case .migrationFailed:
            return "DB migration 실패"
        case .stopped:
            return "중지됨"
        }
    }

    var isRunning: Bool {
        self == .connected || self == .starting
    }

    var isError: Bool {
        switch self {
        case .connectionFailed, .portConflict, .backendInstallationRequired, .backendPathError,
             .uvExecutionFailed, .migrationFailed:
            return true
        default:
            return false
        }
    }

    var systemImage: String {
        switch self {
        case .checking:
            return "arrow.trianglehead.2.clockwise"
        case .connected:
            return "checkmark.circle.fill"
        case .starting:
            return "play.circle"
        case .connectionFailed:
            return "xmark.circle.fill"
        case .portConflict:
            return "network.slash"
        case .backendInstallationRequired:
            return "externaldrive.badge.questionmark"
        case .backendPathError:
            return "folder.badge.questionmark"
        case .uvExecutionFailed:
            return "terminal.fill"
        case .migrationFailed:
            return "externaldrive.badge.xmark"
        case .stopped:
            return "stop.circle"
        }
    }
}

enum BackendLaunchPreflightResult: Equatable {
    case ready(String)
    case backendPathMissing
    case uvMissing
    case portConflict
}

enum BackendLifecyclePolicy {
    static func preflight(
        healthAvailable: Bool,
        portInUse: Bool,
        backendDirectoryExists: Bool,
        uvExecutablePath: String?,
        canRunWithoutUV: Bool = false
    ) -> BackendLaunchPreflightResult {
        if healthAvailable {
            return .ready("")
        }
        if portInUse {
            return .portConflict
        }
        guard backendDirectoryExists else {
            return .backendPathMissing
        }
        if canRunWithoutUV {
            return .ready(uvExecutablePath ?? "")
        }
        guard let uvExecutablePath, !uvExecutablePath.isEmpty else {
            return .uvMissing
        }
        return .ready(uvExecutablePath)
    }

    static func canStopBackend(isOwnedByApp: Bool) -> Bool {
        isOwnedByApp
    }
}
