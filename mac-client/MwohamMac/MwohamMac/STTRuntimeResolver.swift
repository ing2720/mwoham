//
//  STTRuntimeResolver.swift
//  MwohamMac
//

import Foundation

enum STTRuntimeStatus: Equatable, StatusPresentable {
    case ready
    case missingWhisperCLI
    case missingModel
    case whisperCLINotExecutable
    case missingMicrophonePermission
    case unknownError(String)

    var label: String {
        switch self {
        case .ready:
            return "STT 사용 가능"
        case .missingWhisperCLI:
            return "Whisper 실행 파일 없음"
        case .missingModel:
            return "Whisper 모델 없음"
        case .whisperCLINotExecutable:
            return "Whisper 실행 권한 없음"
        case .missingMicrophonePermission:
            return "마이크 권한 필요"
        case .unknownError:
            return "STT 상태 확인 실패"
        }
    }

    var detail: String {
        switch self {
        case .ready:
            return "Mwoham은 로컬 Whisper STT를 사용할 수 있습니다."
        case .missingWhisperCLI:
            return "Whisper 실행 파일을 찾을 수 없습니다. 앱을 다시 설치하거나 포함된 런타임이 있는 배포판을 사용하세요."
        case .missingModel:
            return "Whisper 모델 파일을 찾을 수 없습니다. 모델 파일이 없으면 회의 전사를 시작할 수 없습니다."
        case .whisperCLINotExecutable:
            return "Whisper 실행 권한이 없습니다. 포함된 whisper-cli 파일의 실행 권한을 확인하세요."
        case .missingMicrophonePermission:
            return "마이크 권한이 필요합니다. 시스템 설정에서 MwohamMac의 마이크 권한을 허용하세요."
        case let .unknownError(message):
            return message
        }
    }

    var startFailureMessage: String? {
        switch self {
        case .ready:
            return nil
        case .missingWhisperCLI:
            return "Whisper 실행 파일을 찾을 수 없어 회의 전사를 시작할 수 없습니다."
        case .missingModel:
            return "STT 모델 파일을 찾을 수 없어 회의 전사를 시작할 수 없습니다."
        case .whisperCLINotExecutable:
            return "Whisper 실행 권한이 없어 회의 전사를 시작할 수 없습니다."
        case .missingMicrophonePermission:
            return "마이크 권한이 없어 회의 전사를 시작할 수 없습니다."
        case let .unknownError(message):
            return "STT 런타임 상태를 확인할 수 없어 회의 전사를 시작할 수 없습니다. \(message)"
        }
    }

    var isRunning: Bool {
        self == .ready
    }

    var isError: Bool {
        self != .ready
    }

    var systemImage: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .missingWhisperCLI, .missingModel:
            return "externaldrive.badge.questionmark"
        case .whisperCLINotExecutable:
            return "lock.trianglebadge.exclamationmark"
        case .missingMicrophonePermission:
            return "mic.badge.xmark"
        case .unknownError:
            return "exclamationmark.triangle.fill"
        }
    }
}

enum STTRuntimeResourceSource: String, Equatable {
    case bundled
    case configuredOverride
    case applicationSupport
    case devFallback
    case missing

    var label: String {
        switch self {
        case .bundled:
            return "번들됨"
        case .configuredOverride:
            return "사용자 설정"
        case .applicationSupport:
            return "Application Support"
        case .devFallback:
            return "개발환경 fallback"
        case .missing:
            return "없음"
        }
    }
}

struct STTRuntimeResolvedResource: Equatable {
    let source: STTRuntimeResourceSource
    let url: URL?
    let exists: Bool
    let isExecutable: Bool
    let fileSizeBytes: Int64?

    var pathText: String {
        url?.path ?? "-"
    }

    var fileSizeText: String {
        guard let fileSizeBytes else {
            return "확인할 수 없음"
        }
        return ByteCountFormatter.string(
            fromByteCount: fileSizeBytes,
            countStyle: .file
        )
    }
}

struct STTRuntimeResourceCandidate: Identifiable, Equatable {
    let source: STTRuntimeResourceSource
    let url: URL
    let exists: Bool
    let isExecutable: Bool

    var id: String {
        url.standardizedFileURL.path
    }

    var path: String {
        url.path
    }

    var displayName: String {
        "\(source.label) - \(url.path)"
    }
}

struct STTRuntimeCandidates: Equatable {
    let whisperCLI: [STTRuntimeResourceCandidate]
    let model: [STTRuntimeResourceCandidate]
}

struct STTRuntimeReadiness: Equatable {
    let status: STTRuntimeStatus
    let whisperCLI: STTRuntimeResolvedResource
    let model: STTRuntimeResolvedResource

    var isReady: Bool {
        status == .ready
    }

    var configuration: LocalWhisperConfiguration? {
        guard isReady,
              let binaryURL = whisperCLI.url,
              let modelURL = model.url else {
            return nil
        }
        return LocalWhisperConfiguration(
            binaryURL: binaryURL,
            modelURL: modelURL,
            language: "ko"
        )
    }
}

struct STTRuntimeResolver {
    static let sttDirectoryName = "STT"
    static let whisperCLIFileName = "whisper-cli"
    static let modelFileName = "ggml-large-v3-turbo.bin"
    static let sttWhisperCLIPathEnvKey = "STT_WHISPER_CLI_PATH"
    static let sttModelPathEnvKey = "STT_MODEL_PATH"

    var resourceURL: URL?
    var applicationSupportURL: URL
    var configuredWhisperCLIPath: String?
    var configuredModelPath: String?
    var devWhisperCLIPath: String?
    var devModelPath: String?
    var allowsDevFallback: Bool
    var fileManager: FileManager

    init(
        resourceURL: URL? = Bundle.main.resourceURL,
        applicationSupportURL: URL = STTRuntimeResolver.defaultApplicationSupportURL(),
        configuredWhisperCLIPath: String? = UserDefaults.standard.string(forKey: LocalWhisperSettings.binaryPathKey),
        configuredModelPath: String? = UserDefaults.standard.string(forKey: LocalWhisperSettings.modelPathKey),
        devWhisperCLIPath: String? = "/opt/homebrew/bin/whisper-cli",
        devModelPath: String? = nil,
        allowsDevFallback: Bool = _isDebugAssertConfiguration(),
        fileManager: FileManager = .default
    ) {
        self.resourceURL = resourceURL
        self.applicationSupportURL = applicationSupportURL
        self.configuredWhisperCLIPath = configuredWhisperCLIPath
        self.configuredModelPath = configuredModelPath
        self.devWhisperCLIPath = devWhisperCLIPath
        self.devModelPath = devModelPath
        self.allowsDevFallback = allowsDevFallback
        self.fileManager = fileManager
    }

    func resolve() -> STTRuntimeReadiness {
        let whisperCLI = resolveWhisperCLI()
        let model = resolveModel()
        let status = status(whisperCLI: whisperCLI, model: model)
        return STTRuntimeReadiness(
            status: status,
            whisperCLI: whisperCLI,
            model: model
        )
    }

    func backendEnvironmentValues() -> [String: String] {
        let readiness = resolve()
        var values: [String: String] = [:]
        if let whisperCLIURL = readiness.whisperCLI.url,
           readiness.whisperCLI.exists {
            values[Self.sttWhisperCLIPathEnvKey] = whisperCLIURL.path
        }
        if let modelURL = readiness.model.url,
           readiness.model.exists {
            values[Self.sttModelPathEnvKey] = modelURL.path
        }
        return values
    }

    func discoveredCandidates() -> STTRuntimeCandidates {
        STTRuntimeCandidates(
            whisperCLI: discoveredCandidates(from: whisperCLICandidates()),
            model: discoveredCandidates(from: modelCandidates())
        )
    }

    private func resolveWhisperCLI() -> STTRuntimeResolvedResource {
        resolveFirstExisting(candidates: whisperCLICandidates())
    }

    private func resolveModel() -> STTRuntimeResolvedResource {
        resolveFirstExisting(candidates: modelCandidates())
    }

    private func status(
        whisperCLI: STTRuntimeResolvedResource,
        model: STTRuntimeResolvedResource
    ) -> STTRuntimeStatus {
        if !whisperCLI.exists {
            return .missingWhisperCLI
        }
        if !whisperCLI.isExecutable {
            return .whisperCLINotExecutable
        }
        if !model.exists {
            return .missingModel
        }
        return .ready
    }

    private func resolveFirstExisting(
        candidates: [(STTRuntimeResourceSource, URL)]
    ) -> STTRuntimeResolvedResource {
        for candidate in candidates {
            let resource = inspect(source: candidate.0, url: candidate.1)
            if resource.exists {
                return resource
            }
        }
        guard let first = candidates.first else {
            return STTRuntimeResolvedResource(
                source: .missing,
                url: nil,
                exists: false,
                isExecutable: false,
                fileSizeBytes: nil
            )
        }
        return inspect(source: .missing, url: first.1)
    }

    private func discoveredCandidates(
        from candidates: [(STTRuntimeResourceSource, URL)]
    ) -> [STTRuntimeResourceCandidate] {
        candidates.compactMap { candidate in
            let resource = inspect(source: candidate.0, url: candidate.1)
            guard resource.exists,
                  let url = resource.url else {
                return nil
            }
            return STTRuntimeResourceCandidate(
                source: candidate.0,
                url: url,
                exists: resource.exists,
                isExecutable: resource.isExecutable
            )
        }
    }

    private func inspect(
        source: STTRuntimeResourceSource,
        url: URL
    ) -> STTRuntimeResolvedResource {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
        let attributes = exists
            ? try? fileManager.attributesOfItem(atPath: url.path)
            : nil
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
        return STTRuntimeResolvedResource(
            source: exists ? source : .missing,
            url: url,
            exists: exists,
            isExecutable: exists && fileManager.isExecutableFile(atPath: url.path),
            fileSizeBytes: fileSize
        )
    }

    private func whisperCLICandidates() -> [(STTRuntimeResourceSource, URL)] {
        var candidates: [(STTRuntimeResourceSource, URL)] = []
        if let bundled = bundledWhisperCLIURL {
            candidates.append((.bundled, bundled))
        }
        if let configured = normalizedURL(configuredWhisperCLIPath) {
            candidates.append((.configuredOverride, configured))
        }
        candidates.append((.applicationSupport, applicationSupportWhisperCLIURL))
        if allowsDevFallback,
           let devWhisperCLIPath,
           let dev = normalizedURL(devWhisperCLIPath) {
            candidates.append((.devFallback, dev))
        }
        return deduplicate(candidates)
    }

    private func modelCandidates() -> [(STTRuntimeResourceSource, URL)] {
        var candidates: [(STTRuntimeResourceSource, URL)] = []
        if let bundled = bundledModelURL {
            candidates.append((.bundled, bundled))
        }
        if let configured = normalizedURL(configuredModelPath) {
            candidates.append((.configuredOverride, configured))
        }
        candidates.append((.applicationSupport, applicationSupportModelURL))
        if allowsDevFallback,
           let devModelPath,
           let dev = normalizedURL(devModelPath) {
            candidates.append((.devFallback, dev))
        }
        return deduplicate(candidates)
    }

    private var bundledWhisperCLIURL: URL? {
        resourceURL?
            .appendingPathComponent(Self.sttDirectoryName)
            .appendingPathComponent(Self.whisperCLIFileName)
    }

    private var bundledModelURL: URL? {
        resourceURL?
            .appendingPathComponent(Self.sttDirectoryName)
            .appendingPathComponent("models")
            .appendingPathComponent(Self.modelFileName)
    }

    private var applicationSupportWhisperCLIURL: URL {
        applicationSupportURL
            .appendingPathComponent("stt")
            .appendingPathComponent(Self.whisperCLIFileName)
    }

    private var applicationSupportModelURL: URL {
        applicationSupportURL
            .appendingPathComponent("models")
            .appendingPathComponent(Self.modelFileName)
    }

    private func normalizedURL(_ path: String?) -> URL? {
        guard let path else {
            return nil
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
    }

    private func deduplicate(
        _ candidates: [(STTRuntimeResourceSource, URL)]
    ) -> [(STTRuntimeResourceSource, URL)] {
        var seen: Set<String> = []
        return candidates.filter { candidate in
            seen.insert(candidate.1.standardizedFileURL.path).inserted
        }
    }

    static func defaultApplicationSupportURL() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
        return baseURL.appendingPathComponent("Mwoham")
    }
}
