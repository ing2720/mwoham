//
//  STTUIState.swift
//  MwohamMac
//

import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import Speech

enum STTDisplayState: Equatable, StatusPresentable {
    case localWhisperAvailable
    case localWhisperActive
    case configurationRequired(String)
    case appleSpeech
    case appleSpeechFallback
    case processing
    case error(String)

    var label: String {
        switch self {
        case .localWhisperAvailable:
            return "Local Whisper 사용 가능"
        case .localWhisperActive:
            return "Local Whisper 사용 중"
        case .configurationRequired:
            return "Local Whisper 설정 필요"
        case .appleSpeech:
            return "Apple Speech 사용 중"
        case .appleSpeechFallback:
            return "Apple Speech fallback 사용 중"
        case .processing:
            return "STT 처리 중"
        case .error:
            return "STT 오류 발생"
        }
    }

    var detail: String? {
        switch self {
        case let .configurationRequired(message), let .error(message):
            return message
        default:
            return nil
        }
    }

    var isRunning: Bool {
        switch self {
        case .localWhisperAvailable, .localWhisperActive, .appleSpeech,
             .appleSpeechFallback, .processing:
            return true
        case .configurationRequired, .error:
            return false
        }
    }

    var isError: Bool {
        switch self {
        case .configurationRequired, .error:
            return true
        default:
            return false
        }
    }

    var systemImage: String {
        switch self {
        case .localWhisperAvailable, .localWhisperActive:
            return "cpu"
        case .configurationRequired:
            return "gearshape.badge.questionmark"
        case .appleSpeech:
            return "waveform"
        case .appleSpeechFallback:
            return "arrow.triangle.branch"
        case .processing:
            return "ellipsis.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}

struct WhisperSettingsInspection: Equatable {
    let binaryPath: String
    let modelPath: String
    let binaryExists: Bool
    let binaryIsExecutable: Bool
    let modelExists: Bool
    let modelFileSizeBytes: Int64?
    let binarySourceLabel: String
    let modelSourceLabel: String
    let runtimeStatus: STTRuntimeStatus

    static func inspect(
        binaryPath: String,
        modelPath: String,
        fileManager: FileManager = .default
    ) -> WhisperSettingsInspection {
        let readiness = STTRuntimeResolver(
            configuredWhisperCLIPath: binaryPath,
            configuredModelPath: modelPath,
            fileManager: fileManager
        ).resolve()

        return WhisperSettingsInspection(
            binaryPath: readiness.whisperCLI.url?.path ?? "",
            modelPath: readiness.model.url?.path ?? "",
            binaryExists: readiness.whisperCLI.exists,
            binaryIsExecutable: readiness.whisperCLI.isExecutable,
            modelExists: readiness.model.exists,
            modelFileSizeBytes: readiness.model.fileSizeBytes,
            binarySourceLabel: readiness.whisperCLI.source.label,
            modelSourceLabel: readiness.model.source.label,
            runtimeStatus: readiness.status
        )
    }

    var state: STTDisplayState {
        switch runtimeStatus {
        case .ready:
            return .localWhisperAvailable
        case .missingWhisperCLI, .missingModel, .whisperCLINotExecutable,
             .missingMicrophonePermission, .unknownError:
            return .configurationRequired(runtimeStatus.detail)
        }
    }

    var modelFileSizeText: String {
        guard let modelFileSizeBytes else {
            return "확인할 수 없음"
        }
        return ByteCountFormatter.string(
            fromByteCount: modelFileSizeBytes,
            countStyle: .file
        )
    }

}

struct PermissionIssue: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    var isWarning: Bool = false
}

struct STTPermissionInspection {
    let speechRecognitionAuthorized: Bool
    let microphoneAuthorized: Bool
    let screenRecordingAuthorized: Bool
    let accessibilityAuthorized: Bool

    static func current() -> STTPermissionInspection {
        STTPermissionInspection(
            speechRecognitionAuthorized:
                SFSpeechRecognizer.authorizationStatus() == .authorized,
            microphoneAuthorized:
                AVCaptureDevice.authorizationStatus(for: .audio)
                    == .authorized,
            screenRecordingAuthorized: CGPreflightScreenCaptureAccess(),
            accessibilityAuthorized: AXIsProcessTrusted()
        )
    }

    func issues(for source: MeetingAudioSource) -> [PermissionIssue] {
        var issues: [PermissionIssue] = []
        if !speechRecognitionAuthorized {
            issues.append(
                PermissionIssue(
                    id: "speech_recognition",
                    title: "음성 인식 권한 없음",
                    message: "시스템 설정에서 음성 인식 권한을 허용해 주세요."
                )
            )
        }
        if source.requiresMicrophone && !microphoneAuthorized {
            issues.append(
                PermissionIssue(
                    id: "microphone",
                    title: "마이크 권한 없음",
                    message: "시스템 설정에서 마이크 권한을 허용해 주세요."
                )
            )
        }
        if source.requiresSystemAudio && !screenRecordingAuthorized {
            issues.append(
                PermissionIssue(
                    id: "screen_recording",
                    title: "화면 기록 권한 없음",
                    message: "시스템 오디오 수집을 위해 화면 기록 권한을 허용해 주세요."
                )
            )
        }
        return issues
    }

    var accessibilityIssue: PermissionIssue? {
        guard !accessibilityAuthorized else {
            return nil
        }
        return PermissionIssue(
            id: "accessibility",
            title: "접근성 권한 확인 필요",
            message: "일부 앱의 창 제목/상태 추적 정확도가 낮아질 수 있습니다.",
            isWarning: true
        )
    }
}

struct STTSourceDiagnostic: Identifiable, Equatable {
    let id: String
    let sourceLabel: String
    let wasAttempted: Bool
    let wasIncluded: Bool
    let failureReason: String?
    let processingSeconds: TimeInterval?
    let chunkCount: Int
    let acceptedChunkCount: Int
    let rejectedChunkCount: Int
    let rejectReasons: [String: Int]
    let debugExportPath: String?
}

struct STTResultSummary: Equatable {
    static let empty = STTResultSummary(
        didComplete: false,
        succeeded: false,
        usedFallback: false,
        processingSeconds: nil,
        sourceDiagnostics: []
    )

    let didComplete: Bool
    let succeeded: Bool
    let usedFallback: Bool
    let processingSeconds: TimeInterval?
    let sourceDiagnostics: [STTSourceDiagnostic]

    var acceptedChunkCount: Int {
        sourceDiagnostics.reduce(0) { $0 + $1.acceptedChunkCount }
    }

    var rejectedChunkCount: Int {
        sourceDiagnostics.reduce(0) { $0 + $1.rejectedChunkCount }
    }

    var processingTimeText: String {
        guard let processingSeconds else {
            return "아직 처리 결과 없음"
        }
        return String(format: "%.2f초", processingSeconds)
    }

    var resultText: String {
        guard didComplete else {
            return "아직 처리 결과 없음"
        }
        if usedFallback {
            return succeeded ? "fallback 전사 저장 성공" : "fallback 전사 실패"
        }
        return succeeded ? "전사 저장 성공" : "전사 실패"
    }

    var fallbackText: String {
        usedFallback ? "사용함" : "사용하지 않음"
    }

    var chunkSummaryText: String {
        guard didComplete else {
            return "아직 처리 결과 없음"
        }
        return "채택 \(acceptedChunkCount)개 / 제외 \(rejectedChunkCount)개"
    }
}

enum STTRejectReasonLabel {
    static let orderedKeys = [
        "subtitle_ad_hallucination",
        "repeated_phrase",
        "dot_heavy",
        "low_unique_ratio",
        "empty_or_punctuation",
    ]

    static func label(for key: String) -> String {
        switch key {
        case "subtitle_ad_hallucination":
            return "자막/광고성 환각"
        case "repeated_phrase":
            return "반복 문구"
        case "dot_heavy":
            return "점 반복"
        case "low_unique_ratio":
            return "낮은 고유 단어 비율"
        case "empty_or_punctuation":
            return "빈 결과 또는 문장부호"
        case "repeated_across_chunks":
            return "chunk 간 반복"
        case "process_error":
            return "Whisper 실행 오류"
        case "chunking_error":
            return "오디오 chunk 생성 오류"
        default:
            return key.replacingOccurrences(of: "_", with: " ")
        }
    }
}
