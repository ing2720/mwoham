//
//  DevTrackingAutomationPolicy.swift
//  MwohamMac
//

import Foundation

enum DevTrackingRecordingTransition {
    case started
    case paused
    case resumed
    case stopped
}

enum DevTrackingAutomationAction: Equatable {
    case start
    case stop
    case none
}

enum DevTrackingStartDecision: Equatable {
    case start(URL)
    case alreadyRunning
    case blocked(String)
}

enum DevTrackingAutomationPolicy {
    static func action(for transition: DevTrackingRecordingTransition) -> DevTrackingAutomationAction {
        switch transition {
        case .started:
            return .start
        case .stopped:
            return .stop
        case .paused, .resumed:
            return .none
        }
    }

    static func startDecision(
        backendConnected: Bool,
        isRunning: Bool,
        repoURL: URL,
        fileManager: FileManager = .default
    ) -> DevTrackingStartDecision {
        guard backendConnected else {
            return .blocked("Dev Tracking: backend 연결이 없어 시작하지 않음")
        }
        guard !isRunning else {
            return .alreadyRunning
        }

        let standardizedURL = repoURL.standardizedFileURL
        if standardizedURL.pathComponents.contains("Desktop") {
            return .blocked(
                "Dev Tracking 오류: Desktop 경로는 감시 대상으로 사용할 수 없습니다."
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .blocked("Dev Tracking 오류: 추적 repo 경로를 찾을 수 없습니다.")
        }
        guard fileManager.fileExists(
            atPath: standardizedURL.appendingPathComponent(".git").path
        ) else {
            return .blocked("Dev Tracking 오류: repo 경로에 .git이 없습니다.")
        }

        return .start(standardizedURL)
    }
}
