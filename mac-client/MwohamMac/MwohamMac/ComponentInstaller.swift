//
//  ComponentInstaller.swift
//  MwohamMac
//

import Foundation

nonisolated struct ComponentInstallationResult: Equatable {
    let manifest: ComponentManifest
    let messages: [String]
}

nonisolated struct ComponentInstaller {
    enum InstallationError: LocalizedError {
        case zipPayloadUnsupported(String)

        var errorDescription: String? {
            switch self {
            case let .zipPayloadUnsupported(path):
                return "zip payload 설치는 아직 지원하지 않습니다: \(path)"
            }
        }
    }

    let paths: MwohamPaths
    let resourceURL: URL?
    let fileManager: FileManager

    init(
        paths: MwohamPaths = MwohamPaths(),
        resourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.resourceURL = resourceURL
        self.fileManager = fileManager
    }

    @discardableResult
    func installRequiredComponents(reinstall: Bool = false) throws -> ComponentInstallationResult {
        try paths.ensureDirectories(fileManager: fileManager)
        var manifest = try ComponentManifest.loadOrCreate(
            at: paths.componentManifestPath,
            paths: paths,
            fileManager: fileManager
        )
        var messages: [String] = []

        try installBackend(
            reinstall: reinstall,
            manifest: &manifest,
            messages: &messages
        )
        try installSTTRuntime(
            reinstall: reinstall,
            manifest: &manifest,
            messages: &messages
        )

        manifest.updatedAt = Date()
        try manifest.write(to: paths.componentManifestPath)
        return ComponentInstallationResult(manifest: manifest, messages: messages)
    }

    private func installBackend(
        reinstall: Bool,
        manifest: inout ComponentManifest,
        messages: inout [String]
    ) throws {
        if directoryExists(paths.backendDir), !reinstall {
            manifest.backend.path = paths.backendDir.path
            manifest.backend.status = .installed
            messages.append("backend already installed: \(paths.backendDir.path)")
            return
        }

        if reinstall, fileManager.fileExists(atPath: paths.backendDir.path) {
            try fileManager.removeItem(at: paths.backendDir)
        }

        if let source = resourceDirectory(named: "backend") {
            try copyDirectory(from: source, to: paths.backendDir)
            manifest.backend.path = paths.backendDir.path
            manifest.backend.status = .installed
            messages.append("backend installed from bundled Resources/backend")
            return
        }

        if let payload = resourceFile(named: "backend_payload.zip") {
            manifest.backend.path = paths.backendDir.path
            manifest.backend.status = .missing
            messages.append("backend payload found but zip install is not implemented: \(payload.path)")
            return
        }

        manifest.backend.path = paths.backendDir.path
        manifest.backend.status = .missing
        messages.append("backend missing: \(paths.backendDir.path)")
    }

    private func installSTTRuntime(
        reinstall: Bool,
        manifest: inout ComponentManifest,
        messages: inout [String]
    ) throws {
        if reinstall, fileManager.fileExists(atPath: paths.sttRoot.path) {
            try fileManager.removeItem(at: paths.sttRoot)
            try paths.ensureDirectories(fileManager: fileManager)
        }

        let cliURL = paths.sttBinDir
            .appendingPathComponent(STTRuntimeResolver.whisperCLIFileName)
        if !fileManager.fileExists(atPath: cliURL.path),
           let source = resourceSTTDirectory() {
            try copySTTDirectory(from: source)
            messages.append("STT runtime installed from bundled Resources")
        }

        if let payload = resourceFile(named: "stt_cli_payload.zip"),
           !fileManager.fileExists(atPath: cliURL.path) {
            messages.append("STT payload found but zip install is not implemented: \(payload.path)")
        }

        let modelURL = paths.sttModelsDir
            .appendingPathComponent(STTRuntimeResolver.modelFileName)
        manifest.sttCLI.path = cliURL.path
        manifest.sttCLI.status = sttCLIStatus(at: cliURL)
        manifest.sttModel.name = STTRuntimeResolver.modelFileName
        manifest.sttModel.path = modelURL.path
        manifest.sttModel.status = fileExists(modelURL) ? .installed : .missing

        if manifest.sttCLI.status == .installed {
            messages.append("STT CLI ready: \(cliURL.path)")
        } else {
            messages.append("STT CLI missing or invalid: \(cliURL.path)")
        }
        if manifest.sttModel.status == .installed {
            messages.append("STT model ready: \(modelURL.path)")
        } else {
            messages.append("STT model missing: \(modelURL.path)")
        }
    }

    private func copySTTDirectory(from source: URL) throws {
        try paths.ensureDirectories(fileManager: fileManager)

        let sourceCLIAtRoot = source
            .appendingPathComponent(STTRuntimeResolver.whisperCLIFileName)
        let sourceCLIInBin = source
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(STTRuntimeResolver.whisperCLIFileName)
        let targetCLI = paths.sttBinDir
            .appendingPathComponent(STTRuntimeResolver.whisperCLIFileName)
        if fileExists(sourceCLIInBin) {
            try copyFileReplacingExisting(from: sourceCLIInBin, to: targetCLI)
            try setExecutable(targetCLI)
        } else if fileExists(sourceCLIAtRoot) {
            try copyFileReplacingExisting(from: sourceCLIAtRoot, to: targetCLI)
            try setExecutable(targetCLI)
        }

        for directoryName in ["lib", "models"] {
            let sourceDirectory = source.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
            let targetDirectory = paths.sttRoot.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
            if directoryExists(sourceDirectory) {
                try copyDirectoryContents(
                    from: sourceDirectory,
                    to: targetDirectory
                )
            }
        }
    }

    private func copyDirectory(from source: URL, to target: URL) throws {
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
    }

    private func copyDirectoryContents(from source: URL, to target: URL) throws {
        try fileManager.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        let contents = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        )
        for item in contents {
            try copyFileOrDirectoryReplacingExisting(
                from: item,
                to: target.appendingPathComponent(item.lastPathComponent)
            )
        }
    }

    private func copyFileOrDirectoryReplacingExisting(
        from source: URL,
        to target: URL
    ) throws {
        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            try copyDirectory(from: source, to: target)
        } else {
            try copyFileReplacingExisting(from: source, to: target)
        }
    }

    private func copyFileReplacingExisting(from source: URL, to target: URL) throws {
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
    }

    private func setExecutable(_ url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func sttCLIStatus(at url: URL) -> ComponentInstallStatus {
        guard fileExists(url) else {
            return .missing
        }
        return fileManager.isExecutableFile(atPath: url.path)
            ? .installed
            : .invalid
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

    private func resourceFile(named name: String) -> URL? {
        guard let resourceURL else {
            return nil
        }
        let url = resourceURL.appendingPathComponent(name)
        return fileExists(url) ? url : nil
    }

    private func fileExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }
}
