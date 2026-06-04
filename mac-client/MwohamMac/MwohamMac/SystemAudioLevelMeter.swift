//
//  SystemAudioLevelMeter.swift
//  MwohamMac
//

import AudioToolbox
import CoreMedia
import Foundation

struct SystemAudioLevel {
    let rmsDB: Double
    let peakDB: Double
}

enum SystemAudioLevelMeter {
    static func calculateAudioLevel(_ sampleBuffer: CMSampleBuffer) -> SystemAudioLevel? {
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

            let values = normalizedSamples(
                data: data,
                byteCount: Int(buffer.mDataByteSize),
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
        return SystemAudioLevel(
            rmsDB: decibels(fromLinearValue: rms),
            peakDB: decibels(fromLinearValue: peak)
        )
    }

    private static func normalizedSamples(
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

    private static func normalizedFloatSamples(
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

    private static func normalizedIntegerSamples(
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

    private static func decibels(fromLinearValue value: Double) -> Double {
        let minimumValue = 0.000001
        return 20 * log10(max(value, minimumValue))
    }
}
