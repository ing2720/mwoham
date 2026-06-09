//
//  FullMeetingSpeechTranscriptionProvider.swift
//  MwohamMac
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

final class FullMeetingSpeechTranscriptionProvider: NSObject, SpeechTranscriptionProvider, SCStreamOutput, SCStreamDelegate {
    private let systemAudioQueue = DispatchQueue(label: "com.mwoham.full-meeting-system-audio")
    private let appendQueue = DispatchQueue(label: "com.mwoham.full-meeting-speech-append")
    private let audioEngine = AVAudioEngine()
    private var stream: SCStream?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var onStatusChange: (@MainActor (String) -> Void)?
    private var onTranscript: (@MainActor (SpeechTranscriptUpdate) async -> Void)?
    private var isStopping = false
    private var microphoneBufferCount = 0
    private var systemAudioBufferCount = 0
    private var appendedBufferCount = 0
    private var appendedMicrophoneBufferCount = 0
    private var appendedSystemAudioBufferCount = 0
    private var skippedSilentMicrophoneBufferCount = 0
    private var skippedSilentSystemAudioBufferCount = 0
    private var lowLevelMicrophoneBufferStreak = 0
    private var lowLevelSystemAudioBufferStreak = 0
    private var lastMicrophoneLevelDescription = "마이크 level 확인 전"
    private var lastSystemAudioLevelDescription = "시스템 오디오 level 확인 전"
    private var microphoneActive = false
    private var systemAudioActive = false
    private let minimumSpeechRMSDB = -75.0
    private let minimumSpeechPeakDB = -65.0
    private let consecutiveLowLevelBuffersBeforeSkipping = 8
    private let speechFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    var isRunning: Bool {
        recognitionTask != nil || audioEngine.isRunning || stream != nil
    }

    func start(
        localeIdentifier: String = "ko-KR",
        onTranscript: @escaping @MainActor (SpeechTranscriptUpdate) async -> Void,
        onStatusChange: @escaping @MainActor (String) -> Void
    ) async throws {
        await stop()
        resetDiagnostics()
        isStopping = false
        self.onTranscript = onTranscript
        self.onStatusChange = onStatusChange

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechTranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        speechRecognizer = recognizer
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else {
                    return
                }

                if let result {
                    await self.onTranscript?(
                        SpeechTranscriptUpdate(
                            text: result.bestTranscription.formattedString,
                            isFinal: result.isFinal
                        )
                    )
                    self.onStatusChange?(
                        result.isFinal ? "회의 전체 최종 전사 수신됨" : "Apple Speech 전사 결과 수신 중"
                    )
                }

                if let error, !self.isStopping {
                    self.onStatusChange?("회의 전체 전사 실패: \(SpeechRecognitionErrorFormatter.describe(error)), \(self.diagnosticSummary())")
                    await self.stop()
                }
            }
        }
        await emitStatus("회의 전체 전사 준비 중, Apple Speech task started")

        var inputErrors: [String] = []
        do {
            try startMicrophoneCapture()
            microphoneActive = true
            await emitStatus("마이크 입력 수신 준비됨")
        } catch {
            inputErrors.append("마이크 입력 실패: \(SpeechRecognitionErrorFormatter.describe(error))")
        }

        do {
            try await startSystemAudioCapture()
            systemAudioActive = true
            await emitStatus("시스템 오디오 입력 수신 준비됨")
        } catch {
            inputErrors.append("시스템 오디오 입력 실패: \(SpeechRecognitionErrorFormatter.describe(error))")
        }

        guard microphoneActive || systemAudioActive else {
            await stop()
            throw FullMeetingSpeechTranscriptionError.noInputAvailable(inputErrors.joined(separator: " / "))
        }

        if inputErrors.isEmpty {
            await emitStatus("회의 전체 전사 중, 마이크 입력 수신 중 / 시스템 오디오 입력 수신 중")
        } else {
            await emitStatus("회의 전체 전사 중, \(inputErrors.joined(separator: " / "))")
        }
    }

    func stop() async {
        isStopping = true
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                await emitStatus("회의 전체 시스템 오디오 종료 오류: \(error.localizedDescription)")
            }
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        stream = nil
        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
        microphoneActive = false
        systemAudioActive = false
        resetDiagnostics()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid else {
            return
        }

        systemAudioBufferCount += 1
        guard let buffer = SystemAudioPCMBufferConverter.makePCMBuffer(
            from: sampleBuffer,
            targetFormat: speechFormat
        ) else {
            Task { @MainActor [weak self] in
                self?.onStatusChange?("시스템 오디오 buffer 변환 실패")
            }
            return
        }
        guard shouldAppendSpeechBuffer(
            buffer,
            sourceLabel: "시스템 오디오",
            skippedCounter: &skippedSilentSystemAudioBufferCount,
            lowLevelStreak: &lowLevelSystemAudioBufferStreak,
            lastLevelDescription: &lastSystemAudioLevelDescription
        ) else {
            return
        }
        appendedSystemAudioBufferCount += 1
        appendToSpeechRequest(buffer)

        if systemAudioBufferCount == 1 || systemAudioBufferCount % 100 == 0 {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.onStatusChange?("회의 전체 전사 중, \(self.diagnosticSummary())")
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.isStopping else {
                return
            }
            self.stream = nil
            self.systemAudioActive = false
            self.onStatusChange?("시스템 오디오 입력 실패: \(SpeechRecognitionErrorFormatter.describe(error))")
        }
    }

    private func startMicrophoneCapture() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw SpeechTranscriptionError.inputNodeUnavailable
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self,
                  let speechBuffer = SystemAudioPCMBufferConverter.convert(buffer, to: self.speechFormat) else {
                return
            }
            self.microphoneBufferCount += 1
            guard self.shouldAppendSpeechBuffer(
                speechBuffer,
                sourceLabel: "마이크",
                skippedCounter: &self.skippedSilentMicrophoneBufferCount,
                lowLevelStreak: &self.lowLevelMicrophoneBufferStreak,
                lastLevelDescription: &self.lastMicrophoneLevelDescription
            ) else {
                return
            }
            self.appendedMicrophoneBufferCount += 1
            self.appendToSpeechRequest(speechBuffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startSystemAudioCapture() async throws {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            if !CGPreflightScreenCaptureAccess() {
                throw SystemAudioSpeechTranscriptionError.screenCapturePermissionRequired
            }
        }

        let content = try await SCShareableContent.current
        guard let captureTarget = SystemAudioDisplayCaptureTarget.make(from: content) else {
            throw SystemAudioSpeechTranscriptionError.captureUnavailable
        }

        let display = captureTarget.display
        let configuration = SCStreamConfiguration()
        configuration.width = max(display.width, 2)
        configuration.height = max(display.height, 2)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        if #available(macOS 13.0, *) {
            configuration.excludesCurrentProcessAudio = true
        }

        let stream = SCStream(
            filter: captureTarget.makeDisplayWideFilter(),
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    private func appendToSpeechRequest(_ buffer: AVAudioPCMBuffer) {
        appendedBufferCount += 1
        appendQueue.async { [weak self, buffer] in
            self?.recognitionRequest?.append(buffer)
        }
    }

    private func shouldAppendSpeechBuffer(
        _ buffer: AVAudioPCMBuffer,
        sourceLabel: String,
        skippedCounter: inout Int,
        lowLevelStreak: inout Int,
        lastLevelDescription: inout String
    ) -> Bool {
        guard let level = SystemAudioLevelMeter.calculateAudioLevel(buffer) else {
            lastLevelDescription = "\(sourceLabel) level 확인 불가"
            lowLevelStreak = 0
            return true
        }

        let isVeryLowLevel = level.rmsDB <= minimumSpeechRMSDB && level.peakDB <= minimumSpeechPeakDB
        lowLevelStreak = isVeryLowLevel ? lowLevelStreak + 1 : 0
        lastLevelDescription = "\(sourceLabel) RMS \(String(format: "%.1f", level.rmsDB)) dB, peak \(String(format: "%.1f", level.peakDB)) dB, low streak \(lowLevelStreak)"
        if isVeryLowLevel && lowLevelStreak >= consecutiveLowLevelBuffersBeforeSkipping {
            skippedCounter += 1
            return false
        }
        return true
    }

    private func emitStatus(_ status: String) async {
        await MainActor.run {
            onStatusChange?(status)
        }
    }

    private func resetDiagnostics() {
        microphoneBufferCount = 0
        systemAudioBufferCount = 0
        appendedBufferCount = 0
        appendedMicrophoneBufferCount = 0
        appendedSystemAudioBufferCount = 0
        skippedSilentMicrophoneBufferCount = 0
        skippedSilentSystemAudioBufferCount = 0
        lowLevelMicrophoneBufferStreak = 0
        lowLevelSystemAudioBufferStreak = 0
        lastMicrophoneLevelDescription = "마이크 level 확인 전"
        lastSystemAudioLevelDescription = "시스템 오디오 level 확인 전"
    }

    private func diagnosticSummary() -> String {
        "마이크 buffers \(microphoneBufferCount), appended \(appendedMicrophoneBufferCount), skipped silent \(skippedSilentMicrophoneBufferCount), \(lastMicrophoneLevelDescription), \(inputLevelSummary(appended: appendedMicrophoneBufferCount, skipped: skippedSilentMicrophoneBufferCount)), 시스템 오디오 buffers \(systemAudioBufferCount), appended \(appendedSystemAudioBufferCount), skipped silent \(skippedSilentSystemAudioBufferCount), \(lastSystemAudioLevelDescription), \(inputLevelSummary(appended: appendedSystemAudioBufferCount, skipped: skippedSilentSystemAudioBufferCount)), total appended \(appendedBufferCount), gate RMS \(Int(minimumSpeechRMSDB))dB peak \(Int(minimumSpeechPeakDB))dB streak \(consecutiveLowLevelBuffersBeforeSkipping), format \(Int(speechFormat.sampleRate))Hz \(speechFormat.channelCount)ch float32 non-interleaved"
    }

    private func inputLevelSummary(appended: Int, skipped: Int) -> String {
        let total = appended + skipped
        let ratio = total > 0 ? Double(skipped) / Double(total) : 0
        let ratioDescription = "skip ratio \(String(format: "%.1f", ratio * 100))%"
        guard skipped >= 100, appended <= max(5, skipped / 20) else {
            return "\(ratioDescription), input level normal"
        }
        return "\(ratioDescription), 입력 레벨 낮음"
    }
}

enum FullMeetingSpeechTranscriptionError: LocalizedError {
    case noInputAvailable(String)

    var errorDescription: String? {
        switch self {
        case .noInputAvailable(let reason):
            return "회의 전체 입력을 사용할 수 없습니다: \(reason)"
        }
    }
}
