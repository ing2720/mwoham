//
//  AppleSpeechTranscriptionProvider.swift
//  MwohamMac
//

import AVFoundation
import Foundation
import Speech

struct SpeechTranscriptUpdate {
    let text: String
    let isFinal: Bool
}

protocol SpeechTranscriptionProvider: AnyObject {
    var isRunning: Bool { get }

    func requestAuthorization() async throws
    func start(
        localeIdentifier: String,
        onTranscript: @escaping @MainActor (SpeechTranscriptUpdate) async -> Void,
        onStatusChange: @escaping @MainActor (String) -> Void
    ) async throws
    func stop() async
}

enum SpeechTranscriptionError: LocalizedError {
    case speechRecognitionDenied
    case microphoneDenied
    case recognizerUnavailable
    case inputNodeUnavailable

    var errorDescription: String? {
        switch self {
        case .speechRecognitionDenied:
            return "음성 인식 권한이 필요합니다. 시스템 설정에서 음성 인식을 허용해 주세요."
        case .microphoneDenied:
            return "마이크 권한이 필요합니다. 시스템 설정에서 마이크 접근을 허용해 주세요."
        case .recognizerUnavailable:
            return "현재 음성 인식을 사용할 수 없습니다."
        case .inputNodeUnavailable:
            return "마이크 입력을 사용할 수 없습니다."
        }
    }
}

@MainActor
final class AppleSpeechTranscriptionProvider: SpeechTranscriptionProvider {
    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechRecognizer: SFSpeechRecognizer?
    private var isStopping = false

    var isRunning: Bool {
        audioEngine.isRunning
    }

    func requestAuthorization() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            throw SpeechTranscriptionError.speechRecognitionDenied
        }

        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneAllowed else {
            throw SpeechTranscriptionError.microphoneDenied
        }
    }

    func start(
        localeIdentifier: String = "ko-KR",
        onTranscript: @escaping @MainActor (SpeechTranscriptUpdate) async -> Void,
        onStatusChange: @escaping @MainActor (String) -> Void
    ) async throws {
        await stop()
        isStopping = false

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechTranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw SpeechTranscriptionError.inputNodeUnavailable
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        speechRecognizer = recognizer
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    await onTranscript(
                        SpeechTranscriptUpdate(text: text, isFinal: result.isFinal)
                    )
                }

                if error != nil && !self.isStopping {
                    onStatusChange("Speech 인식 오류")
                    await self.stop()
                }
            }
        }

        onStatusChange("회의 전사 중")
    }

    func stop() async {
        isStopping = true
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
    }
}
