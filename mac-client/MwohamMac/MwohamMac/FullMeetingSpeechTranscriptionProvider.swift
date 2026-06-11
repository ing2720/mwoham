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

final class FullMeetingSpeechTranscriptionProvider: NSObject, FullMeetingSpeechTranscriptionProviding, SCStreamOutput, SCStreamDelegate {
    private let systemAudioQueue = DispatchQueue(label: "com.mwoham.full-meeting-system-audio")
    private let appendQueue = DispatchQueue(label: "com.mwoham.full-meeting-speech-append")
    private let microphoneWhisperRecordingQueue = DispatchQueue(
        label: "com.mwoham.full-meeting-whisper-microphone"
    )
    private let systemAudioWhisperRecordingQueue = DispatchQueue(
        label: "com.mwoham.full-meeting-whisper-system-audio"
    )
    private let audioEngine = AVAudioEngine()
    private let whisperConfigurationProvider: () -> LocalWhisperConfigurationResolution
    private let whisperTranscriber: LocalWhisperMeetingTranscriber
    private var stream: SCStream?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var whisperConfiguration: LocalWhisperConfiguration?
    private var whisperConfigurationUnavailableReason: String?
    private var microphoneAudioRecorder: TemporaryMeetingAudioRecorder?
    private var systemAudioRecorder: TemporaryMeetingAudioRecorder?
    private var microphoneAudioRecordingError: String?
    private var systemAudioRecordingError: String?
    private var debugAudioExportEnabled = false
    private var onStatusChange: (@MainActor (String) -> Void)?
    private var onTranscript: (@MainActor (SpeechTranscriptUpdate) async -> Void)?
    private var isStopping = false
    private var microphoneBufferCount = 0
    private var systemAudioBufferCount = 0
    private var appendedBufferCount = 0
    private var appendedMicrophoneBufferCount = 0
    private var appendedSystemAudioBufferCount = 0
    private var whisperRecordedMicrophoneBufferCount = 0
    private var whisperRecordedSystemAudioBufferCount = 0
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

    init(
        whisperConfigurationProvider: @escaping () -> LocalWhisperConfigurationResolution = {
            LocalWhisperSettings.resolve()
        },
        whisperTranscriber: LocalWhisperMeetingTranscriber = LocalWhisperMeetingTranscriber()
    ) {
        self.whisperConfigurationProvider = whisperConfigurationProvider
        self.whisperTranscriber = whisperTranscriber
        super.init()
    }

    var isRunning: Bool {
        recognitionTask != nil || audioEngine.isRunning || stream != nil
    }

    var preferredEngineDescription: String {
        switch whisperConfigurationProvider() {
        case .available:
            return "Local Whisper microphone + system audio 시간순 병합, Apple Speech fallback"
        case .unavailable(let reason):
            return "Apple Speech (\(reason))"
        }
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
        prepareTemporaryWhisperRecording()

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        if let recognizer, recognizer.isAvailable {
            startAppleSpeechRecognition(
                recognizer: recognizer,
                onTranscript: onTranscript
            )
            await emitStatus("회의 전체 전사 준비 중, Apple Speech fallback started")
        } else if whisperConfiguration == nil {
            throw SpeechTranscriptionError.recognizerUnavailable
        } else {
            await emitStatus("Apple Speech fallback 사용 불가, Local Whisper용 오디오 수집 계속")
        }

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
            await emitStatus(
                "회의 전체 전사 중, Whisper microphone + system audio 별도 수집 / transcript 병합"
            )
        } else {
            await emitStatus("회의 전체 전사 중, \(inputErrors.joined(separator: " / "))")
        }
    }

    private func startAppleSpeechRecognition(
        recognizer: SFSpeechRecognizer,
        onTranscript: @escaping @MainActor (SpeechTranscriptUpdate) async -> Void
    ) {
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
                    let reason = SpeechRecognitionErrorFormatter.describe(error)
                    if self.hasAvailableWhisperRecorder {
                        self.stopSpeechRecognition()
                        self.onStatusChange?(
                            "Apple Speech fallback 실패, Local Whisper 오디오 수집 계속: \(reason)"
                        )
                    } else {
                        self.onStatusChange?(
                            "회의 전체 전사 실패: \(reason), \(self.diagnosticSummary())"
                        )
                        await self.stop()
                    }
                }
            }
        }
    }

    func stop() async {
        isStopping = true
        await stopCaptureInputs()
        drainAudioQueues()
        stopSpeechRecognition()
        cleanupTemporaryWhisperRecording()
        resetRuntimeState()
    }

    func finalizeMeetingTranscription() async -> FullMeetingTranscriptionFinalization {
        isStopping = true
        await stopCaptureInputs()
        drainAudioQueues()

        let configuration = whisperConfiguration
        let unavailableReason = whisperConfigurationUnavailableReason
        stopSpeechRecognition()

        defer {
            cleanupTemporaryWhisperRecording()
            resetRuntimeState()
        }

        guard let configuration else {
            let reason = unavailableReason ?? "Whisper 설정을 사용할 수 없음"
            return .appleSpeechFallback(
                reason: reason,
                sourceResults: TemporaryMeetingAudioSource.allCases.map {
                    failedSourceResult(source: $0, reason: reason)
                }
            )
        }

        let microphoneResult = await finalizeWhisperSource(
            source: .microphone,
            recorder: microphoneAudioRecorder,
            recordingError: microphoneAudioRecordingError,
            configuration: configuration
        )
        let systemAudioResult = await finalizeWhisperSource(
            source: .systemAudio,
            recorder: systemAudioRecorder,
            recordingError: systemAudioRecordingError,
            configuration: configuration
        )
        let sourceResults = [microphoneResult, systemAudioResult]
        let transcripts = sourceResults.compactMap(\.transcript)

        guard let combinedText = LocalWhisperTranscriptMerger.mergeText(transcripts) else {
            let reasons = sourceResults.compactMap(\.failureReason)
            return .appleSpeechFallback(
                reason: reasons.isEmpty
                    ? "유효한 Local Whisper transcript가 없음"
                    : reasons.joined(separator: " / "),
                sourceResults: sourceResults
            )
        }

        return .whisper(
            LocalWhisperFullMeetingTranscript(
                text: combinedText,
                sourceResults: sourceResults,
                temporalMergeApplied: true
            )
        )
    }

    private func finalizeWhisperSource(
        source: TemporaryMeetingAudioSource,
        recorder: TemporaryMeetingAudioRecorder?,
        recordingError: String?,
        configuration: LocalWhisperConfiguration
    ) async -> LocalWhisperSourceResult {
        if let recordingError {
            return failedSourceResult(
                source: source,
                reason: recordingError
            )
        }
        guard let recorder else {
            return failedSourceResult(
                source: source,
                reason: "\(source.rawValue) Whisper recorder를 사용할 수 없음"
            )
        }

        let recording: TemporaryMeetingAudioRecording?
        do {
            recording = try await recorder.finish()
        } catch {
            return failedSourceResult(
                source: source,
                reason: "\(source.rawValue) WAV 생성 실패: "
                    + SpeechRecognitionErrorFormatter.describe(error)
            )
        }
        guard let recording else {
            return failedSourceResult(
                source: source,
                reason: "\(source.rawValue) 오디오가 비어 있음"
            )
        }

        var audioMetadata = recording.metadata
        if debugAudioExportEnabled {
            do {
                let debugURL = try LocalWhisperDebugAudioExporter.export(
                    audioURL: recording.audioURL,
                    source: source
                )
                audioMetadata = audioMetadata.withDebugExportURL(debugURL)
            } catch {
                await emitStatus(
                    "\(source.rawValue) Whisper debug WAV 복사 실패: "
                        + SpeechRecognitionErrorFormatter.describe(error)
                )
            }
        }

        let whisperStartedAt = ProcessInfo.processInfo.systemUptime
        do {
            let attempt = try await whisperTranscriber.transcribe(
                audioURL: recording.audioURL,
                workingDirectoryURL: recording.workingDirectoryURL,
                audioMetadata: audioMetadata,
                configuration: configuration,
                debugAudioExportEnabled: debugAudioExportEnabled
            )
            guard let transcript = attempt.transcript else {
                return LocalWhisperSourceResult(
                    source: source,
                    transcript: nil,
                    audioMetadata: audioMetadata,
                    processingSeconds: attempt.processingSeconds,
                    transcriptLength: 0,
                    chunkDiagnostics: attempt.chunkDiagnostics,
                    failureReason: "\(source.rawValue): 모든 Whisper chunk가 "
                        + "rejected됨 ("
                        + attempt.chunkDiagnostics.rejectReasonSummary
                        + ")"
                )
            }
            return LocalWhisperSourceResult(
                source: source,
                transcript: transcript,
                audioMetadata: audioMetadata,
                processingSeconds: transcript.processingSeconds,
                transcriptLength: transcript.text.count,
                chunkDiagnostics: transcript.chunkDiagnostics,
                failureReason: nil
            )
        } catch {
            return LocalWhisperSourceResult(
                source: source,
                transcript: nil,
                audioMetadata: audioMetadata,
                processingSeconds: ProcessInfo.processInfo.systemUptime
                    - whisperStartedAt,
                transcriptLength: nil,
                chunkDiagnostics: nil,
                failureReason: "\(source.rawValue): "
                    + SpeechRecognitionErrorFormatter.describe(error)
            )
        }
    }

    private func failedSourceResult(
        source: TemporaryMeetingAudioSource,
        reason: String
    ) -> LocalWhisperSourceResult {
        LocalWhisperSourceResult(
            source: source,
            transcript: nil,
            audioMetadata: nil,
            processingSeconds: nil,
            transcriptLength: nil,
            chunkDiagnostics: nil,
            failureReason: reason
        )
    }

    private func stopCaptureInputs() async {
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
        stream = nil
    }

    private func drainAudioQueues() {
        systemAudioQueue.sync {}
        appendQueue.sync {}
        microphoneWhisperRecordingQueue.sync {}
        systemAudioWhisperRecordingQueue.sync {}
    }

    private func stopSpeechRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
    }

    private func resetRuntimeState() {
        microphoneActive = false
        systemAudioActive = false
        onTranscript = nil
        onStatusChange = nil
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
        guard let sourceBuffer = SystemAudioPCMBufferConverter.makePCMBuffer(
            from: sampleBuffer
        ) else {
            Task { @MainActor [weak self] in
                self?.onStatusChange?("시스템 오디오 buffer 변환 실패")
            }
            return
        }
        if let whisperBuffer = SystemAudioPCMBufferConverter.copy(sourceBuffer) {
            appendToSystemAudioWhisperRecording(whisperBuffer)
        } else if systemAudioRecordingError == nil {
            systemAudioRecordingError = "Whisper용 system audio buffer 복사 실패"
        }
        guard let buffer = SystemAudioPCMBufferConverter.convert(
            sourceBuffer,
            to: speechFormat
        ) else {
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
            guard let self else {
                return
            }
            self.microphoneBufferCount += 1
            if let whisperBuffer = SystemAudioPCMBufferConverter.copy(buffer) {
                self.appendToMicrophoneWhisperRecording(whisperBuffer)
            } else if self.microphoneAudioRecordingError == nil {
                self.microphoneAudioRecordingError =
                    "Whisper용 microphone buffer 복사 실패"
            }
            guard let speechBuffer = SystemAudioPCMBufferConverter.convert(
                buffer,
                to: self.speechFormat
            ) else {
                return
            }
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

    private func appendToMicrophoneWhisperRecording(
        _ buffer: AVAudioPCMBuffer
    ) {
        whisperRecordedMicrophoneBufferCount += 1
        microphoneWhisperRecordingQueue.async { [weak self, buffer] in
            guard let self, self.microphoneAudioRecordingError == nil else {
                return
            }
            do {
                try self.microphoneAudioRecorder?.append(buffer)
            } catch {
                self.microphoneAudioRecordingError =
                    "Whisper microphone 오디오 기록 실패: \(error.localizedDescription)"
            }
        }
    }

    private func appendToSystemAudioWhisperRecording(
        _ buffer: AVAudioPCMBuffer
    ) {
        whisperRecordedSystemAudioBufferCount += 1
        systemAudioWhisperRecordingQueue.async { [weak self, buffer] in
            guard let self, self.systemAudioRecordingError == nil else {
                return
            }
            do {
                try self.systemAudioRecorder?.append(buffer)
            } catch {
                self.systemAudioRecordingError =
                    "Whisper system audio 기록 실패: \(error.localizedDescription)"
            }
        }
    }

    private func prepareTemporaryWhisperRecording() {
        cleanupTemporaryWhisperRecording()

        switch whisperConfigurationProvider() {
        case .available(let configuration):
            do {
                microphoneAudioRecorder = try TemporaryMeetingAudioRecorder(
                    source: .microphone
                )
            } catch {
                microphoneAudioRecordingError =
                    "Whisper microphone recorder 준비 실패: \(error.localizedDescription)"
            }
            do {
                systemAudioRecorder = try TemporaryMeetingAudioRecorder(
                    source: .systemAudio
                )
            } catch {
                systemAudioRecordingError =
                    "Whisper system audio recorder 준비 실패: \(error.localizedDescription)"
            }
            whisperConfiguration = configuration
            debugAudioExportEnabled = UserDefaults.standard.bool(
                forKey: LocalWhisperSettings.debugAudioExportEnabledKey
            )
        case .unavailable(let reason):
            whisperConfigurationUnavailableReason = reason
        }
    }

    private func cleanupTemporaryWhisperRecording() {
        microphoneAudioRecorder?.cleanup()
        systemAudioRecorder?.cleanup()
        microphoneAudioRecorder = nil
        systemAudioRecorder = nil
        whisperConfiguration = nil
        whisperConfigurationUnavailableReason = nil
        microphoneAudioRecordingError = nil
        systemAudioRecordingError = nil
        debugAudioExportEnabled = false
    }

    private var hasAvailableWhisperRecorder: Bool {
        whisperConfiguration != nil
            && (
                (microphoneAudioRecorder != nil && microphoneAudioRecordingError == nil)
                    || (systemAudioRecorder != nil && systemAudioRecordingError == nil)
            )
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
        whisperRecordedMicrophoneBufferCount = 0
        whisperRecordedSystemAudioBufferCount = 0
        skippedSilentMicrophoneBufferCount = 0
        skippedSilentSystemAudioBufferCount = 0
        lowLevelMicrophoneBufferStreak = 0
        lowLevelSystemAudioBufferStreak = 0
        lastMicrophoneLevelDescription = "마이크 level 확인 전"
        lastSystemAudioLevelDescription = "시스템 오디오 level 확인 전"
    }

    private func diagnosticSummary() -> String {
        "마이크 buffers \(microphoneBufferCount), Whisper continuous \(whisperRecordedMicrophoneBufferCount), Apple appended \(appendedMicrophoneBufferCount), skipped silent \(skippedSilentMicrophoneBufferCount), \(lastMicrophoneLevelDescription), \(inputLevelSummary(appended: appendedMicrophoneBufferCount, skipped: skippedSilentMicrophoneBufferCount)), 시스템 오디오 buffers \(systemAudioBufferCount), Whisper continuous \(whisperRecordedSystemAudioBufferCount), Apple appended \(appendedSystemAudioBufferCount), skipped silent \(skippedSilentSystemAudioBufferCount), \(lastSystemAudioLevelDescription), \(inputLevelSummary(appended: appendedSystemAudioBufferCount, skipped: skippedSilentSystemAudioBufferCount)), Apple total appended \(appendedBufferCount), Whisper sources microphone+system_audio separate, gate RMS \(Int(minimumSpeechRMSDB))dB peak \(Int(minimumSpeechPeakDB))dB streak \(consecutiveLowLevelBuffersBeforeSkipping), Apple format \(Int(speechFormat.sampleRate))Hz \(speechFormat.channelCount)ch float32 non-interleaved"
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
