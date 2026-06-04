//
//  SystemAudioPCMBufferConverter.swift
//  MwohamMac
//

import AVFoundation
import CoreMedia
import Foundation

enum SystemAudioPCMBufferConverter {
    static func makePCMBuffer(from sampleBuffer: CMSampleBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let sourceBuffer = makeSourcePCMBuffer(from: sampleBuffer) else {
            return nil
        }
        return convert(sourceBuffer, to: targetFormat)
    }

    static func convert(_ sourceBuffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard sourceBuffer.format != targetFormat else {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            return nil
        }

        let ratio = targetFormat.sampleRate / sourceBuffer.format.sampleRate
        let targetFrameCapacity = AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * ratio)) + 1
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

    static func makeMonoFloatPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let sourceBuffer = makeSourcePCMBuffer(from: sampleBuffer),
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sourceBuffer.format.sampleRate,
                  channels: 1,
                  interleaved: false
              ) else {
            return nil
        }
        return convert(sourceBuffer, to: targetFormat)
    }

    static func makeAudioFormatDescription(_ sampleBuffer: CMSampleBuffer) -> String {
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

    static func makePCMBufferFormatDescription(_ buffer: AVAudioPCMBuffer) -> String {
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

    private static func makeSourcePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
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

}
