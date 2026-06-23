//
//  ComponentInstaller.swift
//  MwohamMac
//

import CryptoKit
import Foundation

nonisolated struct ComponentInstallationResult: Equatable {
    let manifest: ComponentManifest
    let messages: [String]
}

nonisolated struct ComponentInstallProgress: Equatable {
    enum Phase: String, Equatable {
        case downloading
        case verifying
        case installing
        case completed
    }

    let component: ComponentName
    let phase: Phase
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let startedAt: Date
    let updatedAt: Date

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else {
            return nil
        }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    var bytesPerSecond: Double {
        let elapsed = max(updatedAt.timeIntervalSince(startedAt), 0.001)
        return Double(downloadedBytes) / elapsed
    }

    var estimatedRemainingSeconds: TimeInterval? {
        guard let totalBytes, totalBytes > downloadedBytes, bytesPerSecond > 0 else {
            return nil
        }
        return Double(totalBytes - downloadedBytes) / bytesPerSecond
    }
}

private final class ComponentDownloadTaskDelegate: NSObject, URLSessionDownloadDelegate {
    private let partialURL: URL
    private let component: ComponentName
    private let startedAt: Date
    private let onProgress: (@MainActor (ComponentInstallProgress) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var completionError: Error?
    private var didComplete = false
    private var lastProgressReport = Date.distantPast

    init(
        partialURL: URL,
        component: ComponentName,
        startedAt: Date,
        onProgress: (@MainActor (ComponentInstallProgress) -> Void)?
    ) {
        self.partialURL = partialURL
        self.component = component
        self.startedAt = startedAt
        self.onProgress = onProgress
    }

    func download(from sourceURL: URL, session: URLSession) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                session.downloadTask(with: sourceURL).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastProgressReport) >= 0.2 else {
            return
        }
        lastProgressReport = now
        report(
            downloadedBytes: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil,
            updatedAt: now
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            completionError = URLError(.badServerResponse)
            return
        }

        do {
            if FileManager.default.fileExists(atPath: partialURL.path) {
                try FileManager.default.removeItem(at: partialURL)
            }
            try FileManager.default.moveItem(at: location, to: partialURL)
            let size = try FileManager.default.attributesOfItem(atPath: partialURL.path)[.size] as? NSNumber
            report(
                downloadedBytes: size?.int64Value ?? downloadTask.countOfBytesReceived,
                totalBytes: size?.int64Value,
                updatedAt: Date()
            )
        } catch {
            completionError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !didComplete else {
            return
        }
        didComplete = true
        if let error {
            continuation?.resume(throwing: error)
        } else if let completionError {
            continuation?.resume(throwing: completionError)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }

    private func report(
        downloadedBytes: Int64,
        totalBytes: Int64?,
        updatedAt: Date
    ) {
        guard let onProgress else {
            return
        }
        let progress = ComponentInstallProgress(
            component: component,
            phase: .downloading,
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            startedAt: startedAt,
            updatedAt: updatedAt
        )
        Task { @MainActor in
            onProgress(progress)
        }
    }
}

nonisolated struct ComponentInstaller {
    static let defaultComponentVersion = "1.1.0"
    static let minimumModelBytes: Int64 = 100 * 1024 * 1024

    enum InstallationError: LocalizedError {
        case invalidURL(String)
        case missingChecksum(ComponentName)
        case checksumMismatch(ComponentName, expected: String, actual: String)
        case backendValidationFailed(String)
        case sttRuntimeValidationFailed(String)
        case modelValidationFailed(String)
        case unsupportedArchive(String)

        var errorDescription: String? {
            switch self {
            case let .invalidURL(value):
                return "컴포넌트 다운로드 URL이 올바르지 않습니다: \(value)"
            case let .missingChecksum(name):
                return "\(name.displayName) 컴포넌트 sha256이 설정되지 않아 설치를 중단했습니다. 릴리즈 asset manifest를 확인하세요."
            case let .checksumMismatch(name, expected, actual):
                return "\(name.displayName) checksum mismatch: expected \(expected), actual \(actual)"
            case let .backendValidationFailed(message):
                return "backend 검증 실패: \(message)"
            case let .sttRuntimeValidationFailed(message):
                return "STT runtime 검증 실패: \(message)"
            case let .modelValidationFailed(message):
                return "STT model 검증 실패: \(message)"
            case let .unsupportedArchive(path):
                return "지원하지 않는 archive 형식입니다: \(path)"
            }
        }
    }

    let paths: MwohamPaths
    let resourceURL: URL?
    let downloadConfig: ComponentDownloadConfig
    let fileManager: FileManager

    init(
        paths: MwohamPaths = MwohamPaths(),
        resourceURL: URL? = Bundle.main.resourceURL,
        downloadConfig: ComponentDownloadConfig = .defaultConfig,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.resourceURL = resourceURL
        self.downloadConfig = downloadConfig
        self.fileManager = fileManager
    }

    @discardableResult
    func installRequiredComponents(reinstall: Bool = false) throws -> ComponentInstallationResult {
        try paths.ensureDirectories(fileManager: fileManager)
        var manifest = try loadManifest()
        var messages: [String] = []

        try installBundledBackendIfAvailable(
            reinstall: reinstall,
            manifest: &manifest,
            messages: &messages
        )
        try installBundledSTTRuntimeIfAvailable(
            reinstall: reinstall,
            manifest: &manifest,
            messages: &messages
        )
        refreshManifestStatuses(manifest: &manifest, messages: &messages)
        try writeManifest(manifest)
        return ComponentInstallationResult(manifest: manifest, messages: messages)
    }

    @discardableResult
    func refreshInstalledComponents() throws -> ComponentInstallationResult {
        try paths.ensureDirectories(fileManager: fileManager)
        var manifest = try loadManifest()
        var messages: [String] = []
        refreshManifestStatuses(manifest: &manifest, messages: &messages)
        try writeManifest(manifest)
        return ComponentInstallationResult(manifest: manifest, messages: messages)
    }

    @discardableResult
    func installDownloadedComponents(
        _ components: [ComponentName] = ComponentName.allCases,
        reinstall: Bool = false,
        onProgress: (@MainActor (ComponentInstallProgress) -> Void)? = nil
    ) async throws -> ComponentInstallationResult {
        try paths.ensureDirectories(fileManager: fileManager)
        var manifest = try loadManifest()
        var messages: [String] = []

        for component in components {
            try await installDownloadedComponent(
                component,
                reinstall: reinstall,
                manifest: &manifest,
                messages: &messages,
                onProgress: onProgress
            )
        }

        refreshManifestStatuses(manifest: &manifest, messages: &messages)
        try writeManifest(manifest)
        return ComponentInstallationResult(manifest: manifest, messages: messages)
    }

    func spec(for name: ComponentName) -> RemoteComponentSpec {
        downloadConfig.spec(for: name)
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func installDownloadedComponent(
        _ name: ComponentName,
        reinstall: Bool,
        manifest: inout ComponentManifest,
        messages: inout [String],
        onProgress: (@MainActor (ComponentInstallProgress) -> Void)?
    ) async throws {
        if !reinstall, installedStatus(for: name) == .installed {
            update(
                name,
                status: .installed,
                manifest: &manifest,
                error: nil
            )
            messages.append("\(name.displayName) already installed: \(ComponentManifest.defaultPath(for: name, paths: paths))")
            return
        }

        let spec = downloadConfig.spec(for: name)
        guard !spec.sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            update(name, status: .failed, manifest: &manifest, error: InstallationError.missingChecksum(name).localizedDescription)
            try writeManifest(manifest)
            throw InstallationError.missingChecksum(name)
        }
        guard let sourceURL = URL(string: spec.url) else {
            update(name, status: .failed, manifest: &manifest, error: InstallationError.invalidURL(spec.url).localizedDescription)
            try writeManifest(manifest)
            throw InstallationError.invalidURL(spec.url)
        }

        update(
            name,
            status: .downloading,
            manifest: &manifest,
            spec: spec,
            error: nil
        )
        try writeManifest(manifest)

        do {
            let downloaded = try await download(
                sourceURL: sourceURL,
                component: name,
                expectedSHA256: spec.sha256,
                onProgress: onProgress
            )
            await reportProgress(
                component: name,
                phase: .installing,
                downloadedBytes: 0,
                totalBytes: nil,
                startedAt: Date(),
                onProgress: onProgress
            )
            switch name {
            case .backend:
                try installBackendArchive(downloaded)
            case .sttCLI:
                try installSTTRuntimeArchive(downloaded)
            case .sttModel:
                try installModelFile(downloaded)
            }
            update(
                name,
                status: .installed,
                manifest: &manifest,
                spec: spec,
                error: nil
            )
            await reportProgress(
                component: name,
                phase: .completed,
                downloadedBytes: 1,
                totalBytes: 1,
                startedAt: Date(),
                onProgress: onProgress
            )
            messages.append("\(name.displayName) installed from \(spec.url)")
        } catch {
            update(
                name,
                status: .failed,
                manifest: &manifest,
                spec: spec,
                error: error.localizedDescription
            )
            try writeManifest(manifest)
            throw error
        }
    }

    private func download(
        sourceURL: URL,
        component: ComponentName,
        expectedSHA256: String,
        onProgress: (@MainActor (ComponentInstallProgress) -> Void)?
    ) async throws -> URL {
        try fileManager.createDirectory(
            at: paths.downloadsDir,
            withIntermediateDirectories: true
        )
        let fileName = sourceURL.lastPathComponent.isEmpty
            ? "\(component.rawValue).download"
            : sourceURL.lastPathComponent
        let finalURL = paths.downloadsDir.appendingPathComponent(fileName)
        let partialURL = finalURL.appendingPathExtension("partial")
        if fileExists(finalURL),
           try Self.sha256(of: finalURL).caseInsensitiveCompare(expectedSHA256) == .orderedSame {
            await reportProgress(
                component: component,
                phase: .completed,
                downloadedBytes: 1,
                totalBytes: 1,
                startedAt: Date(),
                onProgress: onProgress
            )
            return finalURL
        }
        if fileExists(partialURL) {
            try fileManager.removeItem(at: partialURL)
        }

        let startedAt = Date()
        if sourceURL.isFileURL {
            try fileManager.copyItem(at: sourceURL, to: partialURL)
            let size = fileSize(at: partialURL) ?? 0
            await reportProgress(
                component: component,
                phase: .downloading,
                downloadedBytes: size,
                totalBytes: size > 0 ? size : nil,
                startedAt: startedAt,
                onProgress: onProgress
            )
        } else {
            try await downloadRemoteFile(
                sourceURL: sourceURL,
                partialURL: partialURL,
                component: component,
                startedAt: startedAt,
                onProgress: onProgress
            )
        }

        await reportProgress(
            component: component,
            phase: .verifying,
            downloadedBytes: fileSize(at: partialURL) ?? 0,
            totalBytes: fileSize(at: partialURL),
            startedAt: startedAt,
            onProgress: onProgress
        )
        let actual = try Self.sha256(of: partialURL)
        guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            try? fileManager.removeItem(at: partialURL)
            throw InstallationError.checksumMismatch(
                component,
                expected: expectedSHA256,
                actual: actual
            )
        }
        if fileExists(finalURL) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: partialURL, to: finalURL)
        return finalURL
    }

    private func downloadRemoteFile(
        sourceURL: URL,
        partialURL: URL,
        component: ComponentName,
        startedAt: Date,
        onProgress: (@MainActor (ComponentInstallProgress) -> Void)?
    ) async throws {
        let delegate = ComponentDownloadTaskDelegate(
            partialURL: partialURL,
            component: component,
            startedAt: startedAt,
            onProgress: onProgress
        )
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: queue
        )
        defer {
            session.finishTasksAndInvalidate()
        }
        try await delegate.download(from: sourceURL, session: session)
    }

    private func installBackendArchive(_ archiveURL: URL) throws {
        let staging = paths.stagingDir.appendingPathComponent("backend", isDirectory: true)
        try resetDirectory(staging)
        try extractTarGzip(archiveURL, to: staging)
        let payload = normalizedPayloadRoot(staging)
        try validateBackend(at: payload)
        try replaceDirectoryAtomically(from: payload, to: paths.backendDir)
    }

    private func installSTTRuntimeArchive(_ archiveURL: URL) throws {
        let staging = paths.stagingDir.appendingPathComponent("sttCLI", isDirectory: true)
        try resetDirectory(staging)
        try extractTarGzip(archiveURL, to: staging)
        let payload = normalizedPayloadRoot(staging)
        try validateSTTRuntime(at: payload)
        try resetDirectory(paths.sttBinDir)
        try fileManager.createDirectory(at: paths.sttLibDir, withIntermediateDirectories: true)

        let sourceCLI = sttCLIURL(in: payload)
        let targetCLI = paths.sttBinDir.appendingPathComponent(STTRuntimeResolver.whisperCLIFileName)
        try copyFileReplacingExisting(from: sourceCLI, to: targetCLI)
        try setExecutable(targetCLI)

        let sourceLib = payload.appendingPathComponent("lib", isDirectory: true)
        try copyDirectoryContents(from: sourceLib, to: paths.sttLibDir)
    }

    private func installModelFile(_ downloadedURL: URL) throws {
        try validateModel(at: downloadedURL)
        try fileManager.createDirectory(
            at: paths.sttModelsDir,
            withIntermediateDirectories: true
        )
        let target = paths.sttModelsDir.appendingPathComponent(STTRuntimeResolver.modelFileName)
        let staging = paths.stagingDir.appendingPathComponent(STTRuntimeResolver.modelFileName)
        if fileExists(staging) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.copyItem(at: downloadedURL, to: staging)
        try validateModel(at: staging)
        if fileExists(target) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: staging, to: target)
    }

    private func reportProgress(
        component: ComponentName,
        phase: ComponentInstallProgress.Phase,
        downloadedBytes: Int64,
        totalBytes: Int64?,
        startedAt: Date,
        onProgress: (@MainActor (ComponentInstallProgress) -> Void)?
    ) async {
        guard let onProgress else {
            return
        }
        let progress = ComponentInstallProgress(
            component: component,
            phase: phase,
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            startedAt: startedAt,
            updatedAt: Date()
        )
        await onProgress(progress)
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private func installBundledBackendIfAvailable(
        reinstall: Bool,
        manifest: inout ComponentManifest,
        messages: inout [String]
    ) throws {
        if directoryExists(paths.backendDir), !reinstall {
            return
        }
        guard let source = resourceDirectory(named: "backend") else {
            return
        }
        if reinstall, fileManager.fileExists(atPath: paths.backendDir.path) {
            try fileManager.removeItem(at: paths.backendDir)
        }
        try validateBackend(at: source)
        try copyDirectory(from: source, to: paths.backendDir)
        update(.backend, status: .installed, manifest: &manifest, error: nil)
        messages.append("backend installed from bundled Resources/backend")
    }

    private func installBundledSTTRuntimeIfAvailable(
        reinstall: Bool,
        manifest: inout ComponentManifest,
        messages: inout [String]
    ) throws {
        if reinstall, fileManager.fileExists(atPath: paths.sttRoot.path) {
            try fileManager.removeItem(at: paths.sttRoot)
            try paths.ensureDirectories(fileManager: fileManager)
        }

        guard let source = resourceSTTDirectory() else {
            return
        }
        let cliURL = paths.sttBinDir.appendingPathComponent(STTRuntimeResolver.whisperCLIFileName)
        if !fileExists(cliURL) {
            try copySTTDirectory(from: source)
            messages.append("STT runtime installed from bundled Resources")
        }
        update(.sttCLI, status: sttCLIStatus(at: cliURL), manifest: &manifest, error: nil)
        let modelURL = paths.sttModelsDir.appendingPathComponent(STTRuntimeResolver.modelFileName)
        update(.sttModel, status: fileExists(modelURL) ? .installed : .missing, manifest: &manifest, error: nil)
    }

    private func refreshManifestStatuses(
        manifest: inout ComponentManifest,
        messages: inout [String]
    ) {
        for name in ComponentName.allCases {
            let status = installedStatus(for: name)
            update(
                name,
                status: status,
                manifest: &manifest,
                error: status == .installed ? nil : manifest.components[name.rawValue]?.lastError
            )
            messages.append("\(name.displayName) \(status.rawValue): \(ComponentManifest.defaultPath(for: name, paths: paths))")
        }
    }

    private func installedStatus(for name: ComponentName) -> ComponentInstallStatus {
        switch name {
        case .backend:
            guard directoryExists(paths.backendDir) else {
                return .missing
            }
            do {
                try validateBackend(at: paths.backendDir)
                return .installed
            } catch {
                return .invalid
            }
        case .sttCLI:
            return sttCLIStatus(
                at: paths.sttBinDir.appendingPathComponent(STTRuntimeResolver.whisperCLIFileName)
            )
        case .sttModel:
            let modelURL = paths.sttModelsDir.appendingPathComponent(STTRuntimeResolver.modelFileName)
            return fileExists(modelURL) ? .installed : .missing
        }
    }

    private func update(
        _ name: ComponentName,
        status: ComponentInstallStatus,
        manifest: inout ComponentManifest,
        spec: RemoteComponentSpec? = nil,
        error: String?
    ) {
        var record = manifest.components[name.rawValue]
            ?? ComponentManifest.defaultRecord(name: name, paths: paths)
        record.status = status
        record.path = ComponentManifest.defaultPath(for: name, paths: paths)
        if let spec {
            record.sourceURL = spec.url
            record.sha256 = spec.sha256
            record.version = spec.version ?? downloadConfig.version
        } else if record.sourceURL.isEmpty || record.sha256.isEmpty {
            let defaultSpec = downloadConfig.spec(for: name)
            record.sourceURL = defaultSpec.url
            record.sha256 = defaultSpec.sha256
            record.version = record.version.isEmpty
                ? defaultSpec.version ?? downloadConfig.version
                : record.version
        }
        record.updatedAt = Date()
        record.lastError = error
        if status == .installed {
            record.installedAt = record.installedAt ?? Date()
            record.version = record.version.isEmpty ? downloadConfig.version : record.version
        }
        manifest.components[name.rawValue] = record
    }

    private func loadManifest() throws -> ComponentManifest {
        try ComponentManifest.loadOrCreate(
            at: paths.componentManifestPath,
            paths: paths,
            fileManager: fileManager
        )
    }

    private func writeManifest(_ manifest: ComponentManifest) throws {
        var manifest = manifest
        manifest.version = downloadConfig.version
        manifest.updatedAt = Date()
        try manifest.write(to: paths.componentManifestPath)
    }

    private func extractTarGzip(_ archiveURL: URL, to destination: URL) throws {
        guard archiveURL.path.hasSuffix(".tar.gz") || archiveURL.path.hasSuffix(".tgz") else {
            throw InstallationError.unsupportedArchive(archiveURL.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archiveURL.path, "-C", destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallationError.unsupportedArchive(archiveURL.path)
        }
    }

    private func normalizedPayloadRoot(_ root: URL) -> URL {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), contents.count == 1,
           directoryExists(contents[0]) else {
            return root
        }
        return contents[0]
    }

    private func validateBackend(at url: URL) throws {
        for relativePath in ["pyproject.toml", "uv.lock", "alembic.ini", "alembic", "app"] {
            let candidate = url.appendingPathComponent(relativePath)
            if relativePath == "alembic" || relativePath == "app" {
                guard directoryExists(candidate) else {
                    throw InstallationError.backendValidationFailed("\(relativePath) missing")
                }
            } else {
                guard fileExists(candidate) else {
                    throw InstallationError.backendValidationFailed("\(relativePath) missing")
                }
            }
        }
    }

    private func validateSTTRuntime(at url: URL) throws {
        let cliURL = sttCLIURL(in: url)
        guard fileExists(cliURL) else {
            throw InstallationError.sttRuntimeValidationFailed("whisper-cli missing")
        }
        let libDir = url.appendingPathComponent("lib", isDirectory: true)
        for dylib in ["libwhisper.1.dylib", "libggml.0.dylib", "libggml-base.0.dylib", "libomp.dylib"] {
            guard fileExists(libDir.appendingPathComponent(dylib)) else {
                throw InstallationError.sttRuntimeValidationFailed("\(dylib) missing")
            }
        }
    }

    private func validateModel(at url: URL) throws {
        guard fileExists(url) else {
            throw InstallationError.modelValidationFailed("model file missing")
        }
        let bytes = fileSize(url)
        guard bytes >= Self.minimumModelBytes else {
            throw InstallationError.modelValidationFailed("model file too small: \(bytes) bytes")
        }
    }

    private func sttCLIURL(in root: URL) -> URL {
        let inBin = root
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(STTRuntimeResolver.whisperCLIFileName)
        return fileExists(inBin)
            ? inBin
            : root.appendingPathComponent(STTRuntimeResolver.whisperCLIFileName)
    }

    private func copySTTDirectory(from source: URL) throws {
        try paths.ensureDirectories(fileManager: fileManager)

        let targetCLI = paths.sttBinDir.appendingPathComponent(STTRuntimeResolver.whisperCLIFileName)
        let sourceCLI = sttCLIURL(in: source)
        if fileExists(sourceCLI) {
            try copyFileReplacingExisting(from: sourceCLI, to: targetCLI)
            try setExecutable(targetCLI)
        }

        for directoryName in ["lib", "models"] {
            let sourceDirectory = source.appendingPathComponent(directoryName, isDirectory: true)
            let targetDirectory = paths.sttRoot.appendingPathComponent(directoryName, isDirectory: true)
            if directoryExists(sourceDirectory) {
                try copyDirectoryContents(from: sourceDirectory, to: targetDirectory)
            }
        }
    }

    private func replaceDirectoryAtomically(from source: URL, to target: URL) throws {
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent("\(target.lastPathComponent).previous", isDirectory: true)
        if directoryExists(backup) {
            try fileManager.removeItem(at: backup)
        }
        if directoryExists(target) {
            try fileManager.moveItem(at: target, to: backup)
        }
        do {
            try fileManager.moveItem(at: source, to: target)
            if directoryExists(backup) {
                try? fileManager.removeItem(at: backup)
            }
        } catch {
            if directoryExists(backup), !directoryExists(target) {
                try? fileManager.moveItem(at: backup, to: target)
            }
            throw error
        }
    }

    private func resetDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func copyDirectory(from source: URL, to target: URL) throws {
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
    }

    private func copyDirectoryContents(from source: URL, to target: URL) throws {
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in contents {
            try copyFileOrDirectoryReplacingExisting(
                from: item,
                to: target.appendingPathComponent(item.lastPathComponent)
            )
        }
    }

    private func copyFileOrDirectoryReplacingExisting(from source: URL, to target: URL) throws {
        if directoryExists(source) {
            try copyDirectory(from: source, to: target)
        } else {
            try copyFileReplacingExisting(from: source, to: target)
        }
    }

    private func copyFileReplacingExisting(from source: URL, to target: URL) throws {
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: source, to: target)
    }

    private func setExecutable(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func sttCLIStatus(at url: URL) -> ComponentInstallStatus {
        guard fileExists(url) else {
            return .missing
        }
        return fileManager.isExecutableFile(atPath: url.path) ? .installed : .invalid
    }

    private func resourceSTTDirectory() -> URL? {
        resourceDirectory(named: "stt") ?? resourceDirectory(named: "STT")
    }

    private func resourceDirectory(named name: String) -> URL? {
        guard let resourceURL else {
            return nil
        }
        let url = resourceURL.appendingPathComponent(name, isDirectory: true)
        return directoryExists(url) ? url : nil
    }

    private func fileExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
