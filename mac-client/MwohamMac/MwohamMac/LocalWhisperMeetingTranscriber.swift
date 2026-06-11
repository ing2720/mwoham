//
//  LocalWhisperMeetingTranscriber.swift
//  MwohamMac
//

import AVFoundation
import Foundation

struct LocalWhisperConfiguration: Sendable {
    let binaryURL: URL
    let modelURL: URL
    let language: String
}

enum LocalWhisperConfigurationResolution {
    case available(LocalWhisperConfiguration)
    case unavailable(String)
}

enum LocalWhisperSettings {
    static let binaryPathKey = "localWhisperBinaryPath"
    static let modelPathKey = "localWhisperModelPath"
    static let debugAudioExportEnabledKey = "localWhisperDebugAudioExportEnabled"

    static func resolve(
        defaults: UserDefaults = .standard
    ) -> LocalWhisperConfigurationResolution {
        let binaryPath = normalizedPath(defaults.string(forKey: binaryPathKey) ?? "")
        let modelPath = normalizedPath(defaults.string(forKey: modelPathKey) ?? "")

        guard !binaryPath.isEmpty, !modelPath.isEmpty else {
            return .unavailable("Whisper binary/model 경로 미설정")
        }

        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: binaryPath) else {
            return .unavailable("Whisper binary를 실행할 수 없음")
        }
        guard fileManager.fileExists(atPath: modelPath) else {
            return .unavailable("Whisper model을 찾을 수 없음")
        }

        return .available(
            LocalWhisperConfiguration(
                binaryURL: URL(fileURLWithPath: binaryPath),
                modelURL: URL(fileURLWithPath: modelPath),
                language: "ko"
            )
        )
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return NSString(string: trimmed).expandingTildeInPath
    }
}

struct LocalWhisperTranscript: Sendable {
    let text: String
    let processingSeconds: TimeInterval
    let audioMetadata: TemporaryMeetingAudioMetadata
    let chunkDiagnostics: LocalWhisperChunkDiagnostics
}

struct LocalWhisperChunkDiagnostics: Sendable {
    let chunkCount: Int
    let acceptedChunkCount: Int
    let rejectedChunkCount: Int
    let rejectReasons: [String: Int]

    var rejectReasonSummary: String {
        guard !rejectReasons.isEmpty else {
            return "none"
        }
        return rejectReasons.keys.sorted().map {
            "\($0)=\(rejectReasons[$0] ?? 0)"
        }.joined(separator: ",")
    }
}

struct LocalWhisperTranscriptionAttempt: Sendable {
    let transcript: LocalWhisperTranscript?
    let processingSeconds: TimeInterval
    let chunkDiagnostics: LocalWhisperChunkDiagnostics
}

struct LocalWhisperSourceResult: Sendable {
    let source: TemporaryMeetingAudioSource
    let transcript: LocalWhisperTranscript?
    let audioMetadata: TemporaryMeetingAudioMetadata?
    let processingSeconds: TimeInterval?
    let transcriptLength: Int?
    let chunkDiagnostics: LocalWhisperChunkDiagnostics?
    let failureReason: String?

    var isIncluded: Bool {
        transcript != nil
    }
}

struct LocalWhisperFullMeetingTranscript: Sendable {
    let text: String
    let sourceResults: [LocalWhisperSourceResult]

    var processingSeconds: TimeInterval {
        sourceResults.compactMap(\.processingSeconds).reduce(0, +)
    }

    var includedSources: [TemporaryMeetingAudioSource] {
        sourceResults.filter(\.isIncluded).map(\.source)
    }
}

enum FullMeetingTranscriptionFinalization {
    case whisper(LocalWhisperFullMeetingTranscript)
    case appleSpeechFallback(
        reason: String,
        sourceResults: [LocalWhisperSourceResult]
    )
}

protocol FullMeetingSpeechTranscriptionProviding: SpeechTranscriptionProvider {
    var preferredEngineDescription: String { get }
    func finalizeMeetingTranscription() async -> FullMeetingTranscriptionFinalization
}

enum LocalWhisperTranscriptionError: LocalizedError {
    case processLaunchFailed(String)
    case processFailed(Int32, String)
    case timedOut
    case outputMissing
    case emptyTranscript
    case audioChunkingFailed(String)

    var errorDescription: String? {
        switch self {
        case .processLaunchFailed(let message):
            return "Whisper 실행 실패: \(message)"
        case .processFailed(let exitCode, let message):
            let detail = message.isEmpty ? "" : " - \(message)"
            return "Whisper 종료 코드 \(exitCode)\(detail)"
        case .timedOut:
            return "Whisper 처리 시간 초과"
        case .outputMissing:
            return "Whisper 결과 파일이 생성되지 않음"
        case .emptyTranscript:
            return "Whisper 결과가 비어 있음"
        case .audioChunkingFailed(let message):
            return "Whisper WAV chunk 생성 실패: \(message)"
        }
    }
}

enum TemporaryMeetingAudioSource: String, CaseIterable, Hashable, Sendable {
    case microphone
    case systemAudio = "system_audio"

    var transcriptLabel: String {
        "[\(rawValue)]"
    }
}

struct TemporaryMeetingAudioMetadata: Sendable {
    let durationSeconds: TimeInterval
    let captureDurationSeconds: TimeInterval
    let fileSizeBytes: Int64
    let source: TemporaryMeetingAudioSource
    let debugExportURL: URL?

    func withDebugExportURL(_ url: URL) -> TemporaryMeetingAudioMetadata {
        TemporaryMeetingAudioMetadata(
            durationSeconds: durationSeconds,
            captureDurationSeconds: captureDurationSeconds,
            fileSizeBytes: fileSizeBytes,
            source: source,
            debugExportURL: url
        )
    }
}

struct TemporaryMeetingAudioRecording: Sendable {
    let audioURL: URL
    let workingDirectoryURL: URL
    let metadata: TemporaryMeetingAudioMetadata
}

enum TemporaryMeetingAudioRecorderError: LocalizedError {
    case formatChanged
    case conversionFailed(String)
    case convertedAudioMissing

    var errorDescription: String? {
        switch self {
        case .formatChanged:
            return "회의 중 오디오 형식이 변경됨"
        case .conversionFailed(let message):
            return "16 kHz mono PCM16 WAV 변환 실패: \(message)"
        case .convertedAudioMissing:
            return "변환된 Whisper WAV가 비어 있음"
        }
    }
}

final class TemporaryMeetingAudioRecorder {
    private let fileManager: FileManager
    private(set) var directoryURL: URL
    private(set) var audioURL: URL
    private let sourceAudioURL: URL
    private let source: TemporaryMeetingAudioSource
    private var captureStartedAt: TimeInterval?
    private var audioFile: AVAudioFile?
    private var sourceFormat: AVAudioFormat?
    private var writtenFrameCount: AVAudioFramePosition = 0

    init(
        source: TemporaryMeetingAudioSource = .microphone,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.source = source
        Self.cleanupStaleRecordings(fileManager: fileManager)
        directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "mwoham-meeting-whisper-\(source.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
        sourceAudioURL = directoryURL.appendingPathComponent(
            "\(source.rawValue)-source.caf"
        )
        audioURL = directoryURL.appendingPathComponent(
            "\(source.rawValue)-audio.wav"
        )

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    deinit {
        cleanup()
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        if captureStartedAt == nil {
            captureStartedAt = ProcessInfo.processInfo.systemUptime
        }
        if audioFile == nil {
            sourceFormat = buffer.format
            audioFile = try AVAudioFile(
                forWriting: sourceAudioURL,
                settings: buffer.format.settings,
                commonFormat: buffer.format.commonFormat,
                interleaved: buffer.format.isInterleaved
            )
        } else if sourceFormat != buffer.format {
            throw TemporaryMeetingAudioRecorderError.formatChanged
        }

        try audioFile?.write(from: buffer)
        writtenFrameCount += AVAudioFramePosition(buffer.frameLength)
    }

    func finish() async throws -> TemporaryMeetingAudioRecording? {
        let captureDurationSeconds = captureStartedAt.map {
            ProcessInfo.processInfo.systemUptime - $0
        } ?? 0
        audioFile = nil
        guard writtenFrameCount > 0 else {
            return nil
        }

        try await Self.convertToWhisperWAV(
            sourceURL: sourceAudioURL,
            outputURL: audioURL
        )

        let convertedFile = try AVAudioFile(forReading: audioURL)
        let durationSeconds = Double(convertedFile.length)
            / convertedFile.processingFormat.sampleRate
        let attributes = try fileManager.attributesOfItem(atPath: audioURL.path)
        let fileSizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard durationSeconds > 0, fileSizeBytes > 44 else {
            throw TemporaryMeetingAudioRecorderError.convertedAudioMissing
        }

        return TemporaryMeetingAudioRecording(
            audioURL: audioURL,
            workingDirectoryURL: directoryURL,
            metadata: TemporaryMeetingAudioMetadata(
                durationSeconds: durationSeconds,
                captureDurationSeconds: captureDurationSeconds,
                fileSizeBytes: fileSizeBytes,
                source: source,
                debugExportURL: nil
            )
        )
    }

    func cleanup() {
        audioFile = nil
        try? fileManager.removeItem(at: directoryURL)
    }

    private static func cleanupStaleRecordings(fileManager: FileManager) {
        let temporaryDirectory = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        let staleCutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in entries
        where entry.lastPathComponent.hasPrefix("mwoham-meeting-whisper-") {
            let modifiedAt = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if let modifiedAt, modifiedAt < staleCutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private static func convertToWhisperWAV(
        sourceURL: URL,
        outputURL: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let errorPipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = [
                sourceURL.path,
                outputURL.path,
                "-f",
                "WAVE",
                "-d",
                "LEI16@16000",
                "-c",
                "1",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw TemporaryMeetingAudioRecorderError.conversionFailed(
                    error.localizedDescription
                )
            }
            process.waitUntilExit()

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let rawError = String(data: errorData, encoding: .utf8) ?? ""
            let message = String(
                rawError.trimmingCharacters(in: .whitespacesAndNewlines).suffix(500)
            )
            guard process.terminationStatus == 0 else {
                throw TemporaryMeetingAudioRecorderError.conversionFailed(
                    message.isEmpty
                        ? "afconvert 종료 코드 \(process.terminationStatus)"
                        : message
                )
            }
        }.value
    }
}

enum LocalWhisperTranscriptQualityPolicy {
    struct Evaluation: Sendable {
        let acceptedText: String?
        let rejectionReason: String?
    }

    static func evaluate(_ transcript: String) -> Evaluation {
        let sanitized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return Evaluation(
                acceptedText: nil,
                rejectionReason: "empty_or_punctuation"
            )
        }

        let subtitleFiltered = removeBoundarySubtitleAdHallucinations(
            from: sanitized
        )
        if subtitleFiltered.removedAny && subtitleFiltered.text.isEmpty {
            return Evaluation(
                acceptedText: nil,
                rejectionReason: "subtitle_ad_hallucination"
            )
        }

        let candidate = subtitleFiltered.text.isEmpty
            ? sanitized
            : subtitleFiltered.text
        if isDominatedBySubtitleAdHallucination(candidate) {
            return Evaluation(
                acceptedText: nil,
                rejectionReason: "subtitle_ad_hallucination"
            )
        }

        if let reason = rejectionReason(for: candidate) {
            return Evaluation(acceptedText: nil, rejectionReason: reason)
        }
        return Evaluation(acceptedText: candidate, rejectionReason: nil)
    }

    static func rejectionReason(for transcript: String) -> String? {
        let scalars = transcript.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let meaningfulCount = scalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.count
        guard meaningfulCount >= 2 else {
            return "empty_or_punctuation"
        }
        if scalars.count >= 8,
           Double(meaningfulCount) / Double(scalars.count) < 0.35 {
            return "punctuation_dominant"
        }

        let tokens = transcript.unicodeScalars.split {
            !CharacterSet.alphanumerics.contains($0)
        }.map(String.init)
        if hasRepeatedTokenSequence(tokens) {
            return "repeated_phrase"
        }
        if tokens.count >= 8 {
            let uniqueTokenRatio = Double(Set(tokens).count)
                / Double(tokens.count)
            if uniqueTokenRatio < 0.35 {
                return "low_unique_token_ratio"
            }
            let tokenCounts = Dictionary(
                grouping: tokens,
                by: { $0 }
            ).mapValues(\.count)
            if let maximumCount = tokenCounts.values.max(),
               maximumCount >= 3,
               Double(maximumCount) / Double(tokens.count) >= 0.4 {
                return "repeated_token"
            }
        }

        let meaningfulCharacters = transcript.filter {
            $0.unicodeScalars.contains {
                CharacterSet.alphanumerics.contains($0)
            }
        }
        if hasDominantRepeatedCharacterSequence(meaningfulCharacters) {
            return "repeated_character_sequence"
        }
        if meaningfulCharacters.count >= 12 {
            let uniqueCharacterRatio = Double(Set(meaningfulCharacters).count)
                / Double(meaningfulCharacters.count)
            if uniqueCharacterRatio < 0.2 {
                return "low_unique_character_ratio"
            }
        }
        return nil
    }

    static func isRepresentativeTranscript(_ transcript: String) -> Bool {
        evaluate(transcript).rejectionReason == nil
    }

    private static let subtitleAdHallucinationPhrases = [
        "자막 제공",
        "광고를 포함하고 있습니다",
        "한글자막 by",
        "자막 by",
        "번역 by",
        "구독 좋아요",
        "시청해주셔서 감사합니다",
        "subtitles by",
        "translated by",
    ]

    private static func removeBoundarySubtitleAdHallucinations(
        from transcript: String
    ) -> (text: String, removedAny: Bool) {
        var segments = sentenceSegments(from: transcript)
        var removedAny = false

        while let first = segments.first,
              isStandaloneSubtitleAdHallucination(first) {
            segments.removeFirst()
            removedAny = true
        }
        while let last = segments.last,
              isStandaloneSubtitleAdHallucination(last) {
            segments.removeLast()
            removedAny = true
        }

        return (
            segments.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            removedAny
        )
    }

    private static func sentenceSegments(from transcript: String) -> [String] {
        transcript
            .split {
                $0 == "\n" || $0 == "." || $0 == "!" || $0 == "?"
                    || $0 == "。" || $0 == "！" || $0 == "？"
            }
            .map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private static func isStandaloneSubtitleAdHallucination(
        _ sentence: String
    ) -> Bool {
        let normalizedSentence = normalizedSubtitleAdText(sentence)
        if containsWeakSubtitlePhraseOnly(normalizedSentence) {
            return true
        }

        guard let phrase = matchingStrongSubtitleAdPhrase(in: sentence) else {
            return false
        }
        let normalizedPhrase = normalizedSubtitleAdText(phrase)
        guard !normalizedPhrase.isEmpty else {
            return false
        }
        if normalizedSentence == normalizedPhrase {
            return true
        }
        return normalizedSentence.count <= max(48, normalizedPhrase.count * 4)
    }

    private static func isDominatedBySubtitleAdHallucination(
        _ transcript: String
    ) -> Bool {
        guard matchingStrongSubtitleAdPhrase(in: transcript) != nil
                || containsWeakSubtitlePhraseOnly(
                    normalizedSubtitleAdText(transcript)
                ) else {
            return false
        }
        let segments = sentenceSegments(from: transcript)
        guard !segments.isEmpty else {
            return false
        }
        let suspiciousCount = segments.filter {
            isStandaloneSubtitleAdHallucination($0)
        }.count
        return suspiciousCount == segments.count
    }

    private static func matchingStrongSubtitleAdPhrase(
        in text: String
    ) -> String? {
        let normalizedText = normalizedSubtitleAdText(text)
        return subtitleAdHallucinationPhrases.dropFirst().first {
            normalizedText.contains(normalizedSubtitleAdText($0))
        }
    }

    private static func containsWeakSubtitlePhraseOnly(
        _ normalizedText: String
    ) -> Bool {
        let weakPhrase = normalizedSubtitleAdText("자막 제공")
        guard normalizedText.contains(weakPhrase) else {
            return false
        }
        if normalizedText == weakPhrase {
            return true
        }
        return occurrenceCount(of: weakPhrase, in: normalizedText) >= 2
    }

    private static func occurrenceCount(
        of needle: String,
        in haystack: String
    ) -> Int {
        guard !needle.isEmpty else {
            return 0
        }
        var count = 0
        var searchStart = haystack.startIndex
        while let range = haystack.range(
            of: needle,
            range: searchStart..<haystack.endIndex
        ) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    private static func normalizedSubtitleAdText(_ text: String) -> String {
        String(
            text.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }
        )
    }

    private static func hasRepeatedTokenSequence(_ tokens: [String]) -> Bool {
        guard tokens.count >= 3 else {
            return false
        }
        let maximumUnitLength = min(8, tokens.count / 3)
        guard maximumUnitLength > 0 else {
            return false
        }

        for unitLength in 1...maximumUnitLength {
            for start in 0...(tokens.count - unitLength * 3) {
                let unit = Array(tokens[start..<(start + unitLength)])
                var repetitionCount = 1
                var nextStart = start + unitLength
                while nextStart + unitLength <= tokens.count,
                      Array(tokens[nextStart..<(nextStart + unitLength)]) == unit {
                    repetitionCount += 1
                    nextStart += unitLength
                }
                if repetitionCount >= 3,
                   Double(repetitionCount * unitLength)
                    / Double(tokens.count) >= 0.5 {
                    return true
                }
            }
        }
        return false
    }

    private static func hasDominantRepeatedCharacterSequence(
        _ text: String
    ) -> Bool {
        let characters = Array(text)
        guard characters.count >= 6 else {
            return false
        }
        let maximumUnitLength = min(12, characters.count / 3)
        guard maximumUnitLength > 0 else {
            return false
        }

        for unitLength in 1...maximumUnitLength {
            for start in 0...(characters.count - unitLength * 3) {
                let unit = Array(characters[start..<(start + unitLength)])
                var repetitionCount = 1
                var nextStart = start + unitLength
                while nextStart + unitLength <= characters.count,
                      Array(characters[nextStart..<(nextStart + unitLength)])
                        == unit {
                    repetitionCount += 1
                    nextStart += unitLength
                }
                if repetitionCount >= 3,
                   Double(repetitionCount * unitLength)
                    / Double(characters.count) >= 0.5 {
                    return true
                }
            }
        }
        return false
    }
}

struct LocalWhisperAudioChunk: Sendable {
    let index: Int
    let audioURL: URL
}

enum LocalWhisperAudioChunker {
    nonisolated static func makeChunks(
        audioURL: URL,
        workingDirectoryURL: URL,
        chunkDurationSeconds: TimeInterval
    ) throws -> [LocalWhisperAudioChunk] {
        do {
            let inputFile = try AVAudioFile(forReading: audioURL)
            let format = inputFile.processingFormat
            let framesPerChunk = AVAudioFrameCount(
                max(1, floor(format.sampleRate * chunkDurationSeconds))
            )
            var chunks: [LocalWhisperAudioChunk] = []
            var index = 0

            while inputFile.framePosition < inputFile.length {
                let remainingFrames = inputFile.length - inputFile.framePosition
                let frameCount = AVAudioFrameCount(
                    min(AVAudioFramePosition(framesPerChunk), remainingFrames)
                )
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: frameCount
                ) else {
                    throw LocalWhisperTranscriptionError.audioChunkingFailed(
                        "PCM buffer 생성 실패"
                    )
                }
                try inputFile.read(into: buffer, frameCount: frameCount)
                guard buffer.frameLength > 0 else {
                    break
                }

                let chunkURL = workingDirectoryURL.appendingPathComponent(
                    String(format: "chunk-%04d.wav", index)
                )
                let outputFile = try AVAudioFile(
                    forWriting: chunkURL,
                    settings: inputFile.fileFormat.settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
                try outputFile.write(from: buffer)
                chunks.append(
                    LocalWhisperAudioChunk(
                        index: index,
                        audioURL: chunkURL
                    )
                )
                index += 1
            }
            return chunks
        } catch let error as LocalWhisperTranscriptionError {
            throw error
        } catch {
            throw LocalWhisperTranscriptionError.audioChunkingFailed(
                error.localizedDescription
            )
        }
    }
}

struct LocalWhisperCLIOptions: Sendable {
    let arguments: [String]

    nonisolated static func detect(
        binaryURL: URL
    ) -> LocalWhisperCLIOptions {
        let helpText = loadHelpText(binaryURL: binaryURL)
        var arguments: [String] = []

        if helpText.contains("--no-fallback") {
            arguments.append("--no-fallback")
        }
        if helpText.contains("--temperature N") {
            arguments.append(contentsOf: ["--temperature", "0"])
        }
        if helpText.contains("--temperature-inc N") {
            arguments.append(contentsOf: ["--temperature-inc", "0"])
        }
        if helpText.contains("--no-speech-thold N") {
            arguments.append(contentsOf: ["--no-speech-thold", "0.50"])
        }
        if helpText.contains("--beam-size N") {
            arguments.append(contentsOf: ["--beam-size", "5"])
        }
        if helpText.contains("--suppress-nst") {
            arguments.append("--suppress-nst")
        }
        return LocalWhisperCLIOptions(arguments: arguments)
    }

    nonisolated private static func loadHelpText(
        binaryURL: URL
    ) -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["--help"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ""
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: output, encoding: .utf8) ?? ""
    }
}

enum LocalWhisperTranscriptMerger {
    static func mergeText(_ transcripts: [LocalWhisperTranscript]) -> String? {
        let orderedTranscripts = TemporaryMeetingAudioSource.allCases.compactMap {
            source in transcripts.first { $0.audioMetadata.source == source }
        }
        guard !orderedTranscripts.isEmpty else {
            return nil
        }

        if orderedTranscripts.count == 1,
           orderedTranscripts[0].audioMetadata.source == .microphone {
            return orderedTranscripts[0].text
        }

        return orderedTranscripts.map {
            "\($0.audioMetadata.source.transcriptLabel)\n\($0.text)"
        }.joined(separator: "\n\n")
    }
}

enum LocalWhisperDebugAudioExporter {
    static func export(
        audioURL: URL,
        source: TemporaryMeetingAudioSource,
        label: String = "full",
        fileManager: FileManager = .default
    ) throws -> URL {
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let debugDirectoryURL = applicationSupportURL
            .appendingPathComponent("Mwoham", isDirectory: true)
            .appendingPathComponent("debug_audio", isDirectory: true)
        try fileManager.createDirectory(
            at: debugDirectoryURL,
            withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destinationURL = debugDirectoryURL.appendingPathComponent(
            "meeting-\(formatter.string(from: Date()))-"
                + "\(source.rawValue)-\(label)-\(UUID().uuidString).wav"
        )
        try fileManager.copyItem(at: audioURL, to: destinationURL)
        return destinationURL
    }
}

struct LocalWhisperMeetingTranscriber {
    let timeout: TimeInterval
    let chunkDurationSeconds: TimeInterval

    init(
        timeout: TimeInterval = 600,
        chunkDurationSeconds: TimeInterval = 25
    ) {
        self.timeout = timeout
        self.chunkDurationSeconds = chunkDurationSeconds
    }

    func transcribe(
        audioURL: URL,
        workingDirectoryURL: URL,
        audioMetadata: TemporaryMeetingAudioMetadata,
        configuration: LocalWhisperConfiguration,
        debugAudioExportEnabled: Bool
    ) async throws -> LocalWhisperTranscriptionAttempt {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let chunkDurationSeconds = self.chunkDurationSeconds
        let chunks = try await Task.detached(priority: .userInitiated) {
            try LocalWhisperAudioChunker.makeChunks(
                audioURL: audioURL,
                workingDirectoryURL: workingDirectoryURL,
                chunkDurationSeconds: chunkDurationSeconds
            )
        }.value
        let cliOptions = await Task.detached(priority: .userInitiated) {
            LocalWhisperCLIOptions.detect(binaryURL: configuration.binaryURL)
        }.value

        var acceptedTexts: [String] = []
        var rejectReasons: [String: Int] = [:]
        for chunk in chunks {
            if debugAudioExportEnabled {
                _ = try? LocalWhisperDebugAudioExporter.export(
                    audioURL: chunk.audioURL,
                    source: audioMetadata.source,
                    label: String(format: "chunk-%04d", chunk.index)
                )
            }
            do {
                let text = try await transcribeChunk(
                    chunk,
                    workingDirectoryURL: workingDirectoryURL,
                    configuration: configuration,
                    cliOptions: cliOptions
                )
                let evaluation = LocalWhisperTranscriptQualityPolicy
                    .evaluate(text)
                if let reason = evaluation.rejectionReason {
                    rejectReasons[reason, default: 0] += 1
                } else if let acceptedText = evaluation.acceptedText {
                    acceptedTexts.append(acceptedText)
                }
            } catch let error as LocalWhisperTranscriptionError {
                rejectReasons[rejectReason(for: error), default: 0] += 1
            } catch {
                rejectReasons["process_error", default: 0] += 1
            }
        }

        let repeatedChunkCounts = Dictionary(
            grouping: acceptedTexts,
            by: normalizedChunkKey
        ).mapValues(\.count)
        acceptedTexts = acceptedTexts.filter { text in
            let isRepeated = repeatedChunkCounts[normalizedChunkKey(text), default: 0] >= 3
            if isRepeated {
                rejectReasons["repeated_across_chunks", default: 0] += 1
            }
            return !isRepeated
        }

        let processingSeconds = ProcessInfo.processInfo.systemUptime - startedAt
        let diagnostics = LocalWhisperChunkDiagnostics(
            chunkCount: chunks.count,
            acceptedChunkCount: acceptedTexts.count,
            rejectedChunkCount: chunks.count - acceptedTexts.count,
            rejectReasons: rejectReasons
        )
        let combinedText = acceptedTexts.joined(separator: "\n")
        guard !combinedText.isEmpty else {
            return LocalWhisperTranscriptionAttempt(
                transcript: nil,
                processingSeconds: processingSeconds,
                chunkDiagnostics: diagnostics
            )
        }
        return LocalWhisperTranscriptionAttempt(
            transcript: LocalWhisperTranscript(
                text: combinedText,
                processingSeconds: processingSeconds,
                audioMetadata: audioMetadata,
                chunkDiagnostics: diagnostics
            ),
            processingSeconds: processingSeconds,
            chunkDiagnostics: diagnostics
        )
    }

    private func transcribeChunk(
        _ chunk: LocalWhisperAudioChunk,
        workingDirectoryURL: URL,
        configuration: LocalWhisperConfiguration,
        cliOptions: LocalWhisperCLIOptions
    ) async throws -> String {
        let timeout = self.timeout
        return try await Task.detached(priority: .userInitiated) {
            let chunkName = String(format: "whisper-chunk-%04d", chunk.index)
            let outputBaseURL = workingDirectoryURL.appendingPathComponent(
                chunkName
            )
            let outputTextURL = outputBaseURL.appendingPathExtension("txt")
            let errorURL = workingDirectoryURL.appendingPathComponent(
                "\(chunkName)-error.log"
            )
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)

            let errorHandle = try FileHandle(forWritingTo: errorURL)
            defer {
                try? errorHandle.close()
            }

            let process = Process()
            process.executableURL = configuration.binaryURL
            process.arguments = [
                "-m",
                configuration.modelURL.path,
                "-f",
                chunk.audioURL.path,
                "-l",
                configuration.language,
            ] + cliOptions.arguments + [
                "-otxt",
                "-of",
                outputBaseURL.path,
                "-np",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorHandle

            do {
                try process.run()
            } catch {
                throw LocalWhisperTranscriptionError.processLaunchFailed(
                    error.localizedDescription
                )
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit()
                    }
                    throw error
                }
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                throw LocalWhisperTranscriptionError.timedOut
            }
            process.waitUntilExit()
            try? errorHandle.synchronize()

            let rawErrorMessage = (try? String(contentsOf: errorURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorMessage = String(rawErrorMessage.suffix(500))
            guard process.terminationStatus == 0 else {
                throw LocalWhisperTranscriptionError.processFailed(
                    process.terminationStatus,
                    errorMessage
                )
            }
            guard FileManager.default.fileExists(atPath: outputTextURL.path) else {
                throw LocalWhisperTranscriptionError.outputMissing
            }

            let transcript = try String(contentsOf: outputTextURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                throw LocalWhisperTranscriptionError.emptyTranscript
            }
            return transcript
        }.value
    }

    private func rejectReason(
        for error: LocalWhisperTranscriptionError
    ) -> String {
        switch error {
        case .emptyTranscript:
            return "empty"
        case .timedOut:
            return "timeout"
        case .processLaunchFailed, .processFailed, .outputMissing:
            return "process_error"
        case .audioChunkingFailed:
            return "chunking_error"
        }
    }

    private func normalizedChunkKey(_ text: String) -> String {
        String(
            text.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }
        )
    }
}
