//
//  SystemAudioSpeechTranscriptionProvider.swift
//  MwohamMac
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

final class SystemAudioSpeechTranscriptionProvider: NSObject, SpeechTranscriptionProvider, SCStreamOutput, SCStreamDelegate {
    private let sampleQueue = DispatchQueue(label: "com.mwoham.system-audio-speech-transcription")
    private let speechPermissionService: SpeechPermissionServicing
    private var stream: SCStream?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var onStatusChange: (@MainActor (String) -> Void)?
    private var onTranscript: (@MainActor (SpeechTranscriptUpdate) async -> Void)?
    private var receivedBufferCount = 0
    private var appendedBufferCount = 0
    private var lastSampleCount = 0
    private var lastLevelDescription = "level 확인 전"
    private var lastSourceFormatDescription = "source format 확인 전"
    private var lastConvertedFormatDescription = "converted format 확인 전"
    private var didReceiveFirstResult = false
    private var didReceiveFinalResult = false
    private var isStopping = false

    init(speechPermissionService: SpeechPermissionServicing) {
        self.speechPermissionService = speechPermissionService
    }

    var isRunning: Bool {
        stream != nil || recognitionTask != nil
    }

    func start(
        localeIdentifier: String = "ko-KR",
        onTranscript: @escaping @MainActor (SpeechTranscriptUpdate) async -> Void,
        onStatusChange: @escaping @MainActor (String) -> Void
    ) async throws {
        try await startSystemAudioRecognition(
            localeIdentifier: localeIdentifier,
            onTranscript: onTranscript,
            onStatusChange: onStatusChange
        )
    }

    func start(
        localeIdentifier: String = "ko-KR",
        onStatusChange: @escaping @MainActor (String) -> Void,
        onTranscriptChange: @escaping @MainActor (String) -> Void
    ) async throws {
        try await startSystemAudioRecognition(
            localeIdentifier: localeIdentifier,
            onTranscript: { update in
                onTranscriptChange(update.text)
            },
            onStatusChange: onStatusChange
        )
    }

    private func startSystemAudioRecognition(
        localeIdentifier: String,
        onTranscript: @escaping @MainActor (SpeechTranscriptUpdate) async -> Void,
        onStatusChange: @escaping @MainActor (String) -> Void
    ) async throws {
        guard !isRunning else {
            onStatusChange("시스템 오디오 전사 테스트 실행 중")
            return
        }

        self.onStatusChange = onStatusChange
        self.onTranscript = onTranscript
        resetDiagnostics()
        isStopping = false

        if !hasScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            if !hasScreenCaptureAccess() {
                throw SystemAudioSpeechTranscriptionError.screenCapturePermissionRequired
            }
        }

        try await speechPermissionService.requestSpeechRecognitionAuthorization()

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechTranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        recognitionRequest = request
        speechRecognizer = recognizer
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else {
                    return
                }

                if let result {
                    self.didReceiveFirstResult = true
                    self.didReceiveFinalResult = self.didReceiveFinalResult || result.isFinal
                    let text = result.bestTranscription.formattedString
                    await self.onTranscript?(
                        SpeechTranscriptUpdate(text: text, isFinal: result.isFinal)
                    )
                    self.onStatusChange?(
                        result.isFinal ? "시스템 오디오 최종 전사 수신됨" : "시스템 오디오 전사 중"
                    )
                }

                if let error, !self.isStopping {
                    self.onStatusChange?(
                        "시스템 오디오 전사 실패: \(SpeechRecognitionErrorFormatter.describe(error)), \(self.diagnosticSummary())"
                    )
                    await self.stop()
                }
            }
        }

        let content = try await SCShareableContent.current
        guard let captureTarget = SystemAudioDisplayCaptureTarget.make(from: content) else {
            throw SystemAudioSpeechTranscriptionError.captureUnavailable
        }

        let display = captureTarget.display
        let filter = captureTarget.makeDisplayWideFilter()
        let configuration = SCStreamConfiguration()
        configuration.width = max(display.width, 2)
        configuration.height = max(display.height, 2)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        if #available(macOS 13.0, *) {
            configuration.excludesCurrentProcessAudio = true
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream

        onStatusChange("display 전체 시스템 오디오 전사 준비 완료, speech task started, buffer 대기 중")
    }

    func stop() async {
        isStopping = true

        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                updateStatus("시스템 오디오 전사 종료 오류: \(error.localizedDescription)")
            }
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        stream = nil
        recognitionRequest = nil
        recognitionTask = nil
        speechRecognizer = nil
        resetDiagnostics()
        updateStatus("시스템 오디오 전사 테스트 종료됨")
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid else {
            return
        }

        receivedBufferCount += 1
        lastSampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        lastSourceFormatDescription = makeAudioFormatDescription(sampleBuffer)
        lastLevelDescription = makeAudioLevelDescription(sampleBuffer)

        guard let pcmBuffer = makeSpeechFriendlyPCMBuffer(from: sampleBuffer) else {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.onStatusChange?("시스템 오디오 buffer 변환 실패, \(self.diagnosticSummary())")
            }
            return
        }

        recognitionRequest?.append(pcmBuffer)
        appendedBufferCount += 1
        lastConvertedFormatDescription = makePCMBufferFormatDescription(pcmBuffer)

        let status = "buffer 수신 중: buffers \(receivedBufferCount), appended \(appendedBufferCount), samples \(lastSampleCount), source \(lastSourceFormatDescription), converted \(lastConvertedFormatDescription), \(lastLevelDescription)"

        Task { @MainActor [weak self] in
            self?.onStatusChange?(status)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            self.stream = nil
            self.onStatusChange?("시스템 오디오 전사 캡처 오류: \(error.localizedDescription)")
        }
    }

    private func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func makeSpeechFriendlyPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let sourceBuffer = makeSourcePCMBuffer(from: sampleBuffer) else {
            return nil
        }
        return convertToMonoFloatPCMBuffer(sourceBuffer)
    }

    private func makeSourcePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let audioFormat = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        var audioBufferListSize = 0
        var blockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &audioBufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, audioBufferListSize > 0 else {
            return nil
        }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: audioBufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawBufferList.deallocate()
        }

        let sourceBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: sourceBufferList,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            return nil
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourceBufferList)
        let targetBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        guard sourceBuffers.count == targetBuffers.count else {
            return nil
        }

        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let targetData = targetBuffers[index].mData else {
                continue
            }

            let byteCount = min(
                Int(sourceBuffers[index].mDataByteSize),
                Int(targetBuffers[index].mDataByteSize)
            )
            memcpy(targetData, sourceData, byteCount)
            targetBuffers[index].mDataByteSize = UInt32(byteCount)
        }

        return pcmBuffer
    }

    private func convertToMonoFloatPCMBuffer(_ sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceBuffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        guard sourceBuffer.format != targetFormat else {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            return nil
        }

        let targetFrameCapacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * targetFormat.sampleRate / sourceBuffer.format.sampleRate)
        ) + 1
        guard let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: max(targetFrameCapacity, 1)
        ) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: targetBuffer, error: &conversionError) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }

        guard conversionError == nil, status != .error, targetBuffer.frameLength > 0 else {
            return nil
        }

        return targetBuffer
    }

    private func makeAudioFormatDescription(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            return "format 확인 불가"
        }

        let sampleRate = Int(streamDescription.pointee.mSampleRate)
        let channels = Int(streamDescription.pointee.mChannelsPerFrame)
        let bits = Int(streamDescription.pointee.mBitsPerChannel)
        let isFloat = streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isInterleaved = streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return "\(sampleRate)Hz, \(channels)ch, \(bits)bit, \(isFloat ? "float" : "int"), \(isInterleaved ? "interleaved" : "non-interleaved")"
    }

    private func makePCMBufferFormatDescription(_ buffer: AVAudioPCMBuffer) -> String {
        let format = buffer.format
        let commonFormat: String
        switch format.commonFormat {
        case .pcmFormatFloat32:
            commonFormat = "float32"
        case .pcmFormatFloat64:
            commonFormat = "float64"
        case .pcmFormatInt16:
            commonFormat = "int16"
        case .pcmFormatInt32:
            commonFormat = "int32"
        case .otherFormat:
            commonFormat = "other"
        @unknown default:
            commonFormat = "unknown"
        }

        return "\(Int(format.sampleRate))Hz, \(format.channelCount)ch, \(commonFormat), \(format.isInterleaved ? "interleaved" : "non-interleaved"), frames \(buffer.frameLength)"
    }

    private func makeAudioLevelDescription(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let level = SystemAudioLevelMeter.calculateAudioLevel(sampleBuffer) else {
            return "level 확인 불가"
        }

        return "level RMS \(String(format: "%.1f", level.rmsDB)) dB, peak \(String(format: "%.1f", level.peakDB)) dB"
    }

    @MainActor
    private func updateStatus(_ status: String) {
        onStatusChange?(status)
    }

    private func resetDiagnostics() {
        receivedBufferCount = 0
        appendedBufferCount = 0
        lastSampleCount = 0
        lastLevelDescription = "level 확인 전"
        lastSourceFormatDescription = "source format 확인 전"
        lastConvertedFormatDescription = "converted format 확인 전"
        didReceiveFirstResult = false
        didReceiveFinalResult = false
    }

    private func diagnosticSummary() -> String {
        "buffers \(receivedBufferCount), appended \(appendedBufferCount), samples \(lastSampleCount), \(lastLevelDescription), source \(lastSourceFormatDescription), converted \(lastConvertedFormatDescription), firstResult \(didReceiveFirstResult ? "yes" : "no"), finalResult \(didReceiveFinalResult ? "yes" : "no")"
    }
}

enum SystemAudioSpeechTranscriptionError: LocalizedError, Equatable {
    case screenCapturePermissionRequired
    case captureUnavailable

    var errorDescription: String? {
        switch self {
        case .screenCapturePermissionRequired:
            return "화면 기록 권한이 필요합니다. 시스템 설정에서 화면 기록 권한을 허용해 주세요."
        case .captureUnavailable:
            return "시스템 오디오 전사 캡처 대상을 찾을 수 없습니다."
        }
    }
}
