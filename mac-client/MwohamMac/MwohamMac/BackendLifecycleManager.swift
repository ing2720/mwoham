//
//  BackendLifecycleManager.swift
//  MwohamMac
//

import Darwin
import Combine
import Foundation

@MainActor
final class BackendLifecycleManager: ObservableObject {
    nonisolated static let backendDirectoryPathKey = "mwohamBackendDirectoryPath"

    @Published private(set) var state: BackendLifecycleState = .checking
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var recentLogLines: [String] = []
    @Published private(set) var ownsBackendProcess = false

    private let localApiClient: LocalApiClient
    private let backendDirectoryOverride: URL?
    private let fileManager: FileManager
    private var process: Process?
    private var standardOutput: Pipe?
    private var standardError: Pipe?
    private var didAttemptAutomaticStart = false
    private var operationInProgress = false
    private let maxLogLines = 40

    init(
        localApiClient: LocalApiClient,
        backendDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.localApiClient = localApiClient
        self.backendDirectoryOverride = backendDirectory
        self.fileManager = fileManager
    }

    var isBusy: Bool {
        operationInProgress || state == .starting || state == .checking
    }

    var backendDirectoryPath: String {
        let resolved = backendDirectory
        if directoryIsValid(resolved) {
            return resolved.path
        }
        if let configured = Self.configuredBackendDirectory() {
            return "수동 설정 경로를 찾을 수 없음: \(configured.path)"
        }
        return Self.backendDirectorySearchDescription
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
        let backendDirectory = backendDirectory
        let directoryExists = directoryIsValid(backendDirectory)
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
            if let configured = Self.configuredBackendDirectory() {
                lastErrorMessage =
                    "수동 설정한 backend 경로를 찾을 수 없습니다: \(configured.path)"
            } else {
                lastErrorMessage =
                    "backend 경로를 찾을 수 없습니다. 앱 번들 또는 Application Support 기준으로 다시 확인해 주세요."
            }
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
            state = .starting
            guard await runBackendMigrations(
                uvExecutablePath: uvPath,
                backendDirectory: backendDirectory
            ) else {
                return
            }
            launchBackend(
                uvExecutablePath: uvPath,
                backendDirectory: backendDirectory
            )
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

    private func runBackendMigrations(
        uvExecutablePath: String,
        backendDirectory: URL
    ) async -> Bool {
        let paths = MwohamPaths()
        do {
            try paths.ensureDirectories(fileManager: fileManager)
        } catch {
            state = .migrationFailed
            lastErrorMessage =
                "DB migration 준비 실패: Application Support 디렉토리를 생성할 수 없습니다. \(error.localizedDescription)"
            appendLog(lastErrorMessage ?? "")
            return false
        }

        let environment = Self.processEnvironment()
        let command = Self.migrationCommand(
            backendDirectory: backendDirectory,
            uvExecutablePath: uvExecutablePath,
            fileManager: fileManager
        )
        appendLog("DB migration 시작: \(command.display)")
        appendLog("DB migration DATABASE_URL: \(environment["DATABASE_URL"] ?? "unset")")

        let result = await Self.runProcess(
            executableURL: command.executableURL,
            arguments: command.arguments,
            currentDirectoryURL: backendDirectory,
            environment: environment
        )
        result.outputLines.forEach { appendLog("migration: \($0)") }

        guard result.exitCode == 0 else {
            state = .migrationFailed
            lastErrorMessage =
                "DB migration 실패: \(command.display) 종료 코드 \(result.exitCode)"
            appendLog(lastErrorMessage ?? "")
            return false
        }

        appendLog("DB migration 완료")
        return true
    }

    private func launchBackend(
        uvExecutablePath: String,
        backendDirectory: URL
    ) {
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

    private var backendDirectory: URL {
        backendDirectoryOverride
            ?? Self.defaultBackendDirectory(fileManager: fileManager)
    }

    private func directoryIsValid(_ backendDirectory: URL) -> Bool {
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

    private static func migrationCommand(
        backendDirectory: URL,
        uvExecutablePath: String,
        fileManager: FileManager
    ) -> BackendMigrationCommand {
        let venvAlembic = backendDirectory
            .appendingPathComponent(".venv", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("alembic")
        if fileManager.isExecutableFile(atPath: venvAlembic.path) {
            return BackendMigrationCommand(
                executableURL: venvAlembic,
                arguments: ["upgrade", "head"],
                display: "./.venv/bin/alembic upgrade head"
            )
        }
        return BackendMigrationCommand(
            executableURL: URL(fileURLWithPath: uvExecutablePath),
            arguments: ["run", "alembic", "upgrade", "head"],
            display: "uv run alembic upgrade head"
        )
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String]
    ) async -> BackendProcessResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            process.environment = environment
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()
                let output = outputPipe.fileHandleForReading
                    .readDataToEndOfFile()
                let error = errorPipe.fileHandleForReading
                    .readDataToEndOfFile()
                let text = [output, error]
                    .compactMap { String(data: $0, encoding: .utf8) }
                    .joined(separator: "\n")
                return BackendProcessResult(
                    exitCode: process.terminationStatus,
                    outputLines: outputLines(from: text)
                )
            } catch {
                return BackendProcessResult(
                    exitCode: -1,
                    outputLines: [error.localizedDescription]
                )
            }
        }.value
    }

    nonisolated private static func outputLines(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func defaultBackendDirectory(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        filePath: String = #filePath
    ) -> URL {
        let candidates = backendDirectoryCandidates(
            bundle: bundle,
            fileManager: fileManager,
            filePath: filePath
        )
        return candidates.first { candidate in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        } ?? candidates[0]
    }

    nonisolated private static func backendDirectoryCandidates(
        bundle: Bundle,
        fileManager: FileManager,
        filePath: String
    ) -> [URL] {
        var candidates: [URL] = []

        if let configured = configuredBackendDirectory() {
            candidates.append(configured)
        }

        candidates.append(MwohamPaths.defaultAppSupportRoot().appendingPathComponent(
            "backend",
            isDirectory: true
        ))

        if let resourceURL = bundle.resourceURL {
            candidates.append(
                resourceURL.appendingPathComponent("backend", isDirectory: true)
            )
        }

        if _isDebugAssertConfiguration() {
            candidates.append(devBackendDirectory(filePath: filePath))
        }

        return deduplicate(candidates)
    }

    nonisolated private static func configuredBackendDirectory() -> URL? {
        let userDefaultValue = UserDefaults.standard.string(
            forKey: backendDirectoryPathKey
        )
        let environmentValue = ProcessInfo.processInfo.environment[
            "MWOHAM_BACKEND_DIRECTORY"
        ]
        let path = [userDefaultValue, environmentValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let path else {
            return nil
        }
        return URL(
            fileURLWithPath: NSString(string: path).expandingTildeInPath,
            isDirectory: true
        )
    }

    nonisolated private static func devBackendDirectory(filePath: String) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backend", isDirectory: true)
    }

    nonisolated private static func deduplicate(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    private static let backendDirectorySearchDescription =
        "자동 탐색: 수동 설정, Application Support/Mwoham/backend, Bundle.main.resourceURL/backend, 개발 빌드 fallback"

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let paths = MwohamPaths()
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
        environment["DATABASE_URL"] = environment["DATABASE_URL"]
            ?? "sqlite:///\(paths.dataDir.appendingPathComponent("mwoham.sqlite3").path)"
        environment["REPORT_EXPORT_DIR"] = environment["REPORT_EXPORT_DIR"]
            ?? paths.dataDir.appendingPathComponent("exports", isDirectory: true).path
        environment["MWOHAM_LOG_DIR"] = environment["MWOHAM_LOG_DIR"]
            ?? paths.logsDir.path
        environment["UV_CACHE_DIR"] = environment["UV_CACHE_DIR"]
            ?? paths.appSupportRoot
                .appendingPathComponent("uv-cache", isDirectory: true)
                .path
        STTRuntimeResolver().backendEnvironmentValues().forEach { key, value in
            environment[key] = value
        }
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

private struct BackendMigrationCommand: Sendable {
    let executableURL: URL
    let arguments: [String]
    let display: String
}

private struct BackendProcessResult: Sendable {
    let exitCode: Int32
    let outputLines: [String]
}
