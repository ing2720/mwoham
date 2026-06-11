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
}

enum FullMeetingTranscriptionFinalization {
    case whisper(LocalWhisperTranscript)
    case appleSpeechFallback(reason: String)
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
        }
    }
}

final class TemporaryMeetingAudioRecorder {
    private let fileManager: FileManager
    private(set) var directoryURL: URL
    private(set) var audioURL: URL
    private let outputFormat: AVAudioFormat
    private var audioFile: AVAudioFile?
    private var writtenFrameCount: AVAudioFramePosition = 0

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        Self.cleanupStaleRecordings(fileManager: fileManager)
        directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("mwoham-meeting-whisper-\(UUID().uuidString)", isDirectory: true)
        audioURL = directoryURL.appendingPathComponent("meeting-audio.wav")
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        audioFile = try AVAudioFile(
            forWriting: audioURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
    }

    deinit {
        cleanup()
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let audioFile,
              let convertedBuffer = SystemAudioPCMBufferConverter.convert(
                  buffer,
                  to: outputFormat
              ) else {
            return
        }
        try audioFile.write(from: convertedBuffer)
        writtenFrameCount += AVAudioFramePosition(convertedBuffer.frameLength)
    }

    func finish() -> URL? {
        audioFile = nil
        return writtenFrameCount > 0 ? audioURL : nil
    }

    func cleanup() {
        audioFile = nil
        try? fileManager.removeItem(at: directoryURL)
    }

    private static func cleanupStaleRecordings(fileManager: FileManager) {
        let temporaryDirectory = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for entry in entries
        where entry.lastPathComponent.hasPrefix("mwoham-meeting-whisper-") {
            try? fileManager.removeItem(at: entry)
        }
    }
}

struct LocalWhisperMeetingTranscriber {
    let timeout: TimeInterval

    init(timeout: TimeInterval = 600) {
        self.timeout = timeout
    }

    func transcribe(
        audioURL: URL,
        workingDirectoryURL: URL,
        configuration: LocalWhisperConfiguration
    ) async throws -> LocalWhisperTranscript {
        try await Task.detached(priority: .userInitiated) {
            let outputBaseURL = workingDirectoryURL.appendingPathComponent("whisper-transcript")
            let outputTextURL = outputBaseURL.appendingPathExtension("txt")
            let errorURL = workingDirectoryURL.appendingPathComponent("whisper-error.log")
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
                audioURL.path,
                "-l",
                configuration.language,
                "-otxt",
                "-of",
                outputBaseURL.path,
                "-np",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorHandle

            let startedAt = ProcessInfo.processInfo.systemUptime
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

            return LocalWhisperTranscript(
                text: transcript,
                processingSeconds: ProcessInfo.processInfo.systemUptime - startedAt
            )
        }.value
    }
}
