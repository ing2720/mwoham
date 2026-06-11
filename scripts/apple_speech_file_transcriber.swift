import Foundation
import Speech

private enum TranscriberError: LocalizedError {
    case invalidArguments
    case authorizationDenied(SFSpeechRecognizerAuthorizationStatus)
    case recognizerUnavailable
    case recognitionFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: AppleSpeechFileTranscriber <wav-path> <locale> <timeout-seconds>"
        case let .authorizationDenied(status):
            return "Apple Speech authorization was not granted (status: \(status.rawValue))."
        case .recognizerUnavailable:
            return "Apple Speech recognizer is unavailable for the requested locale."
        case let .recognitionFailed(message):
            return "Apple Speech recognition failed: \(message)"
        case .timedOut:
            return "Apple Speech recognition timed out."
        }
    }
}

private final class RecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var transcript: String?
    var error: Error?

    func finish(transcript: String? = nil, error: Error? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !completed else {
            return false
        }
        completed = true
        self.transcript = transcript
        self.error = error
        return true
    }
}

private func requestAuthorization(timeout: TimeInterval) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var authorizationStatus = SFSpeechRecognizer.authorizationStatus()

    if authorizationStatus == .notDetermined {
        SFSpeechRecognizer.requestAuthorization { status in
            authorizationStatus = status
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw TranscriberError.timedOut
        }
    }

    guard authorizationStatus == .authorized else {
        throw TranscriberError.authorizationDenied(authorizationStatus)
    }
}

private func transcribe(
    wavURL: URL,
    localeIdentifier: String,
    timeout: TimeInterval
) throws -> (text: String, processingSeconds: Double) {
    guard let recognizer = SFSpeechRecognizer(
        locale: Locale(identifier: localeIdentifier)
    ), recognizer.isAvailable else {
        throw TranscriberError.recognizerUnavailable
    }

    let request = SFSpeechURLRecognitionRequest(url: wavURL)
    request.shouldReportPartialResults = false
    if #available(macOS 13.0, *) {
        request.addsPunctuation = true
    }

    let state = RecognitionState()
    let semaphore = DispatchSemaphore(value: 0)
    let startedAt = ProcessInfo.processInfo.systemUptime
    let task = recognizer.recognitionTask(with: request) { result, error in
        if let result, result.isFinal {
            if state.finish(transcript: result.bestTranscription.formattedString) {
                semaphore.signal()
            }
            return
        }

        if let error, state.finish(error: error) {
            semaphore.signal()
        }
    }

    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        task.cancel()
        throw TranscriberError.timedOut
    }
    task.cancel()

    if let error = state.error {
        throw TranscriberError.recognitionFailed(error.localizedDescription)
    }

    let text = state.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if text.isEmpty {
        throw TranscriberError.recognitionFailed("empty transcript")
    }

    return (
        text: text,
        processingSeconds: ProcessInfo.processInfo.systemUptime - startedAt
    )
}

private func writeResult(text: String, processingSeconds: Double) throws {
    let payload: [String: Any] = [
        "transcript": text,
        "processing_seconds": processingSeconds,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

@main
private struct AppleSpeechFileTranscriber {
    static func main() {
        do {
            guard CommandLine.arguments.count == 4,
                  let timeout = TimeInterval(CommandLine.arguments[3]),
                  timeout > 0
            else {
                throw TranscriberError.invalidArguments
            }

            let wavURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let localeIdentifier = CommandLine.arguments[2]

            try requestAuthorization(timeout: timeout)
            let result = try transcribe(
                wavURL: wavURL,
                localeIdentifier: localeIdentifier,
                timeout: timeout
            )
            try writeResult(
                text: result.text,
                processingSeconds: result.processingSeconds
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }
}
