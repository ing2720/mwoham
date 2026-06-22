//
//  SpeechPermissionService.swift
//  MwohamMac
//

import AppKit
import Foundation

@MainActor
protocol SpeechPermissionServicing {
    func requestAuthorization() async throws
    func requestSpeechRecognitionAuthorization() async throws
    func isPermissionError(_ error: Error) -> Bool
    func openSpeechRecognitionSettings()
    func openMicrophoneSettings()
    func openScreenRecordingSettings()
    func showPermissionAlert()
}

@MainActor
final class SpeechPermissionService: SpeechPermissionServicing {
    func requestAuthorization() async throws {
        let speechAllowed = await PermissionSettingsOpener
            .requestSpeechRecognitionAccess()
        guard speechAllowed else {
            throw SpeechTranscriptionError.speechRecognitionDenied
        }
        let microphoneAllowed = await PermissionSettingsOpener
            .requestMicrophoneAccess()
        guard microphoneAllowed else {
            throw SpeechTranscriptionError.microphoneDenied
        }
    }

    func requestSpeechRecognitionAuthorization() async throws {
        let speechAllowed = await PermissionSettingsOpener
            .requestSpeechRecognitionAccess()
        guard speechAllowed else {
            throw SpeechTranscriptionError.speechRecognitionDenied
        }
    }

    func isPermissionError(_ error: Error) -> Bool {
        if let speechError = error as? SpeechTranscriptionError {
            return speechError == .speechRecognitionDenied || speechError == .microphoneDenied
        }
        if let systemAudioError = error as? SystemAudioSpeechTranscriptionError {
            return systemAudioError == .screenCapturePermissionRequired
        }
        return false
    }

    func openSpeechRecognitionSettings() {
        PermissionSettingsOpener.openSpeechRecognitionSettings()
    }

    func openMicrophoneSettings() {
        PermissionSettingsOpener.openMicrophoneSettings()
    }

    func openScreenRecordingSettings() {
        PermissionSettingsOpener.openScreenRecordingSettings()
    }

    func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "회의 전사 권한이 필요합니다."
        alert.informativeText = "음성 인식과 마이크 권한을 허용한 뒤 회의 전사를 다시 시작해 주세요."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "음성 인식 설정 열기")
        alert.addButton(withTitle: "마이크 설정 열기")
        alert.addButton(withTitle: "취소")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openSpeechRecognitionSettings()
        case .alertSecondButtonReturn:
            openMicrophoneSettings()
        default:
            break
        }
    }
}
