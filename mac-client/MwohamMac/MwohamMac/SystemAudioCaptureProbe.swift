//
//  SystemAudioCaptureProbe.swift
//  MwohamMac
//

import AppKit
import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioCaptureProbe: NSObject, SCStreamOutput, SCStreamDelegate {
    private let sampleQueue = DispatchQueue(label: "com.mwoham.system-audio-capture-probe")
    private var stream: SCStream?
    private var onStatusChange: (@MainActor (String) -> Void)?
    private var receivedBufferCount = 0

    var isRunning: Bool {
        stream != nil
    }

    func start(onStatusChange: @escaping @MainActor (String) -> Void) async throws {
        guard stream == nil else {
            onStatusChange("시스템 오디오 캡처 테스트 실행 중")
            return
        }

        self.onStatusChange = onStatusChange
        receivedBufferCount = 0

        if !hasScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            if !hasScreenCaptureAccess() {
                throw SystemAudioCaptureProbeError.screenCapturePermissionRequired
            }
        }

        let content = try await SCShareableContent.current
        guard let captureTarget = SystemAudioDisplayCaptureTarget.make(from: content) else {
            throw SystemAudioCaptureProbeError.captureUnavailable
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
        onStatusChange("display 전체 시스템 오디오 캡처 시작됨, buffer 대기 중")
    }

    func stop() async {
        guard let stream else {
            updateStatus("시스템 오디오 캡처 대기 중")
            return
        }

        do {
            try await stream.stopCapture()
            updateStatus("시스템 오디오 캡처 테스트 종료됨")
        } catch {
            updateStatus("시스템 오디오 캡처 종료 오류: \(error.localizedDescription)")
        }

        self.stream = nil
        onStatusChange = nil
        receivedBufferCount = 0
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
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
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let timestampSeconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let formatDescription = makeAudioFormatDescription(sampleBuffer)
        let levelDescription = makeAudioLevelDescription(sampleBuffer)
        let status = "buffer 수신됨: \(receivedBufferCount)개, samples \(sampleCount), \(formatDescription), \(levelDescription), timestamp \(String(format: "%.2f", timestampSeconds))"

        Task { @MainActor [weak self] in
            self?.onStatusChange?(status)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.stream = nil
            self?.onStatusChange?("시스템 오디오 캡처 오류: \(error.localizedDescription)")
        }
    }

    private func makeAudioFormatDescription(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            return "format 확인 불가"
        }

        let sampleRate = Int(streamDescription.pointee.mSampleRate)
        let channels = Int(streamDescription.pointee.mChannelsPerFrame)
        return "\(sampleRate)Hz, \(channels)ch"
    }

    private func makeAudioLevelDescription(_ sampleBuffer: CMSampleBuffer) -> String {
        guard let level = calculateAudioLevel(sampleBuffer) else {
            return "level 확인 불가"
        }

        return "level RMS \(String(format: "%.1f", level.rmsDB)) dB, peak \(String(format: "%.1f", level.peakDB)) dB"
    }

    private func calculateAudioLevel(_ sampleBuffer: CMSampleBuffer) -> AudioLevel? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }

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

        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            return nil
        }

        let flags = streamDescription.pointee.mFormatFlags
        let bitsPerChannel = streamDescription.pointee.mBitsPerChannel
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        var sumSquares = 0.0
        var peak = 0.0
        var totalSamples = 0

        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
                continue
            }

            let byteCount = Int(buffer.mDataByteSize)
            let values = normalizedSamples(
                data: data,
                byteCount: byteCount,
                bitsPerChannel: bitsPerChannel,
                formatFlags: flags
            )

            for value in values {
                let absoluteValue = abs(value)
                sumSquares += value * value
                peak = max(peak, absoluteValue)
                totalSamples += 1
            }
        }

        guard totalSamples > 0 else {
            return nil
        }

        let rms = sqrt(sumSquares / Double(totalSamples))
        return AudioLevel(
            rmsDB: decibels(fromLinearValue: rms),
            peakDB: decibels(fromLinearValue: peak)
        )
    }

    private func normalizedSamples(
        data: UnsafeMutableRawPointer,
        byteCount: Int,
        bitsPerChannel: UInt32,
        formatFlags: AudioFormatFlags
    ) -> [Double] {
        if formatFlags & kAudioFormatFlagIsFloat != 0 {
            return normalizedFloatSamples(data: data, byteCount: byteCount, bitsPerChannel: bitsPerChannel)
        }

        return normalizedIntegerSamples(data: data, byteCount: byteCount, bitsPerChannel: bitsPerChannel)
    }

    private func normalizedFloatSamples(
        data: UnsafeMutableRawPointer,
        byteCount: Int,
        bitsPerChannel: UInt32
    ) -> [Double] {
        if bitsPerChannel == 64 {
            let sampleCount = byteCount / MemoryLayout<Double>.size
            let samples = data.bindMemory(to: Double.self, capacity: sampleCount)
            return (0..<sampleCount).map { samples[$0] }
        }

        let sampleCount = byteCount / MemoryLayout<Float>.size
        let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
        return (0..<sampleCount).map { Double(samples[$0]) }
    }

    private func normalizedIntegerSamples(
        data: UnsafeMutableRawPointer,
        byteCount: Int,
        bitsPerChannel: UInt32
    ) -> [Double] {
        switch bitsPerChannel {
        case 16:
            let sampleCount = byteCount / MemoryLayout<Int16>.size
            let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
            return (0..<sampleCount).map { Double(samples[$0]) / Double(Int16.max) }
        case 32:
            let sampleCount = byteCount / MemoryLayout<Int32>.size
            let samples = data.bindMemory(to: Int32.self, capacity: sampleCount)
            return (0..<sampleCount).map { Double(samples[$0]) / Double(Int32.max) }
        default:
            return []
        }
    }

    private func decibels(fromLinearValue value: Double) -> Double {
        let minimumValue = 0.000001
        return 20 * log10(max(value, minimumValue))
    }

    @MainActor
    private func updateStatus(_ status: String) {
        onStatusChange?(status)
    }
}

private struct AudioLevel {
    let rmsDB: Double
    let peakDB: Double
}

enum SystemAudioCaptureProbeError: LocalizedError {
    case screenCapturePermissionRequired
    case captureUnavailable

    var errorDescription: String? {
        switch self {
        case .screenCapturePermissionRequired:
            return "화면 기록 권한이 필요합니다. 시스템 설정에서 화면 기록 권한을 허용해 주세요."
        case .captureUnavailable:
            return "시스템 오디오 캡처 대상을 찾을 수 없습니다."
        }
    }
}
