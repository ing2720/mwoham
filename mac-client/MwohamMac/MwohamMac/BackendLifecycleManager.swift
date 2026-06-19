//
//  BackendLifecycleManager.swift
//  MwohamMac
//

import Darwin
import Combine
import Foundation

@MainActor
final class BackendLifecycleManager: ObservableObject {
    @Published private(set) var state: BackendLifecycleState = .checking
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var recentLogLines: [String] = []
    @Published private(set) var ownsBackendProcess = false

    private let localApiClient: LocalApiClient
    private let backendDirectory: URL
    private let fileManager: FileManager
    private var process: Process?
    private var standardOutput: Pipe?
    private var standardError: Pipe?
    private var didAttemptAutomaticStart = false
    private var operationInProgress = false
    private let maxLogLines = 40

    init(
        localApiClient: LocalApiClient,
        backendDirectory: URL = URL(
            fileURLWithPath: "/Users/a/Projects/mwoham/backend",
            isDirectory: true
        ),
        fileManager: FileManager = .default
    ) {
        self.localApiClient = localApiClient
        self.backendDirectory = backendDirectory
        self.fileManager = fileManager
    }

    var isBusy: Bool {
        operationInProgress || state == .starting || state == .checking
    }

    var backendDirectoryPath: String {
        backendDirectory.path
    }

    var recentLogText: String {
        recentLogLines.isEmpty
            ? "최근 backend 로그가 없습니다."
            : recentLogLines.joined(separator: "\n")
    }

    func ensureBackendAvailable() async {
        guard !operationInProgress else {
            return
        }
        operationInProgress = true
        defer { operationInProgress = false }

        state = .checking
        lastErrorMessage = nil
        if await healthIsAvailable() {
            state = .connected
            return
        }

        guard !didAttemptAutomaticStart else {
            applyConnectionFailure()
            return
        }
        didAttemptAutomaticStart = true
        await startBackendAfterHealthFailure()
    }

    func checkHealth() async {
        guard !operationInProgress else {
            return
        }
        operationInProgress = true
        defer { operationInProgress = false }

        state = .checking
        lastErrorMessage = nil
        if await healthIsAvailable() {
            state = .connected
        } else if Self.isPortInUse(port: 8765) {
            state = .portConflict
            lastErrorMessage =
                "포트 8765가 사용 중이지만 backend health check에 실패했습니다."
        } else if ownsBackendProcess {
            state = .connectionFailed
            lastErrorMessage = "앱이 시작한 backend가 health check에 응답하지 않습니다."
        } else {
            state = .stopped
        }
    }

    func startBackend() async {
        guard !operationInProgress else {
            return
        }
        operationInProgress = true
        defer { operationInProgress = false }

        lastErrorMessage = nil
        if await healthIsAvailable() {
            state = .connected
            return
        }
        await startBackendAfterHealthFailure()
    }

    func restartBackend() async {
        guard !operationInProgress else {
            return
        }
        guard ownsBackendProcess else {
            lastErrorMessage =
                "외부에서 실행한 backend는 앱에서 재시작할 수 없습니다."
            return
        }

        operationInProgress = true
        stopOwnedProcess(updateState: false)
        try? await Task.sleep(for: .milliseconds(300))
        operationInProgress = false
        await startBackend()
    }

    func stopBackend() {
        guard BackendLifecyclePolicy.canStopBackend(
            isOwnedByApp: ownsBackendProcess
        ) else {
            lastErrorMessage =
                "앱이 직접 시작한 backend만 중지할 수 있습니다."
            return
        }
        stopOwnedProcess(updateState: true)
    }

    private func startBackendAfterHealthFailure() async {
        let directoryExists = directoryIsValid()
        let uvExecutable = Self.resolveUVExecutable()
        let preflight = BackendLifecyclePolicy.preflight(
            healthAvailable: false,
            portInUse: Self.isPortInUse(port: 8765),
            backendDirectoryExists: directoryExists,
            uvExecutablePath: uvExecutable
        )

        switch preflight {
        case .backendPathMissing:
            state = .backendPathError
            lastErrorMessage =
                "backend 경로를 찾을 수 없습니다: \(backendDirectory.path)"
            return
        case .uvMissing:
            state = .uvExecutionFailed
            lastErrorMessage =
                "uv 실행 파일을 찾을 수 없습니다. PATH 또는 Homebrew 설치를 확인해 주세요."
            return
        case .portConflict:
            state = .portConflict
            lastErrorMessage =
                "포트 8765가 사용 중이지만 backend health check에 실패했습니다."
            return
        case let .ready(uvPath):
            launchBackend(uvExecutablePath: uvPath)
        }

        guard ownsBackendProcess else {
            return
        }
        state = .starting
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if await healthIsAvailable() {
                state = .connected
                lastErrorMessage = nil
                return
            }
            if process?.isRunning != true {
                break
            }
        }

        state = .connectionFailed
        lastErrorMessage =
            "backend를 시작했지만 제한 시간 안에 health check가 성공하지 않았습니다."
    }

    private func launchBackend(uvExecutablePath: String) {
        guard process?.isRunning != true else {
            state = .starting
            return
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.currentDirectoryURL = backendDirectory
        process.executableURL = URL(fileURLWithPath: uvExecutablePath)
        process.arguments = [
            "run",
            "uvicorn",
            "app.main:app",
            "--host",
            "127.0.0.1",
            "--port",
            "8765",
            "--reload",
        ]
        process.environment = Self.processEnvironment()
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.consumeOutput(data)
            }
        }
        standardError.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.consumeOutput(data)
            }
        }
        process.terminationHandler = { [weak self, weak process] terminated in
            Task { @MainActor [weak self, weak process] in
                guard let self, let process, process === terminated else {
                    return
                }
                self.clearPipeHandlers()
                if self.process === terminated {
                    self.process = nil
                    self.ownsBackendProcess = false
                    if self.state != .stopped {
                        self.state = .connectionFailed
                        self.lastErrorMessage =
                            "앱이 시작한 backend가 종료되었습니다. 종료 코드 \(terminated.terminationStatus)"
                    }
                }
            }
        }

        do {
            try process.run()
            self.process = process
            self.standardOutput = standardOutput
            self.standardError = standardError
            ownsBackendProcess = true
            appendLog("backend process 시작: pid \(process.processIdentifier)")
        } catch {
            clearPipeHandlers()
            state = .uvExecutionFailed
            lastErrorMessage = "uv 실행 실패: \(error.localizedDescription)"
        }
    }

    private func stopOwnedProcess(updateState: Bool) {
        guard let process, ownsBackendProcess else {
            if updateState {
                state = .stopped
            }
            return
        }
        clearPipeHandlers()
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        ownsBackendProcess = false
        if updateState {
            state = .stopped
            lastErrorMessage = nil
        }
        appendLog("앱 요청으로 backend process 중지")
    }

    private func healthIsAvailable() async -> Bool {
        do {
            let health = try await localApiClient.fetchHealth()
            return health.status == "ok"
        } catch {
            return false
        }
    }

    private func applyConnectionFailure() {
        if Self.isPortInUse(port: 8765) {
            state = .portConflict
            lastErrorMessage =
                "포트 8765가 사용 중이지만 backend health check에 실패했습니다."
        } else {
            state = .connectionFailed
            lastErrorMessage = "backend health check에 실패했습니다."
        }
    }

    private func directoryIsValid() -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(
            atPath: backendDirectory.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private func consumeOutput(_ data: Data) {
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .forEach { appendLog($0) }
    }

    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        recentLogLines.append(trimmed)
        if recentLogLines.count > maxLogLines {
            recentLogLines.removeFirst(recentLogLines.count - maxLogLines)
        }
    }

    private func clearPipeHandlers() {
        standardOutput?.fileHandleForReading.readabilityHandler = nil
        standardError?.fileHandleForReading.readabilityHandler = nil
        standardOutput = nil
        standardError = nil
    }

    private static func resolveUVExecutable() -> String? {
        let environment = processEnvironment()
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidates = pathDirectories.map {
            URL(fileURLWithPath: $0).appendingPathComponent("uv").path
        } + [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let requiredPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] =
            (requiredPaths + [existingPath]).joined(separator: ":")
        return AIProviderBackendEnvironment.applyingAIProviderSettings(
            to: environment,
            settings: AIProviderSettingsStore().settings,
            keyStore: AIProviderKeychainStore()
        )
    }

    private static func isPortInUse(port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) == 0
            }
        }
    }
}
