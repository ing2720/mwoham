//
//  ComponentManifest.swift
//  MwohamMac
//

import Foundation

nonisolated enum ComponentInstallStatus: String, Codable, Equatable, CaseIterable {
    case missing
    case downloading
    case installed
    case failed
    case versionMismatch = "version_mismatch"
    case invalid
}

extension ComponentInstallStatus: StatusPresentable {
    var label: String {
        switch self {
        case .missing:
            return "missing"
        case .downloading:
            return "downloading"
        case .installed:
            return "installed"
        case .failed:
            return "failed"
        case .versionMismatch:
            return "version mismatch"
        case .invalid:
            return "invalid"
        }
    }

    var isRunning: Bool {
        self == .installed || self == .downloading
    }

    var isError: Bool {
        switch self {
        case .missing, .failed, .versionMismatch, .invalid:
            return true
        case .downloading, .installed:
            return false
        }
    }

    var systemImage: String {
        switch self {
        case .missing:
            return "externaldrive.badge.questionmark"
        case .downloading:
            return "arrow.down.circle"
        case .installed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .versionMismatch:
            return "exclamationmark.triangle.fill"
        case .invalid:
            return "externaldrive.badge.xmark"
        }
    }
}

nonisolated enum ComponentName: String, Codable, CaseIterable, Identifiable {
    case backend
    case sttCLI
    case sttModel

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .backend:
            return "backend"
        case .sttCLI:
            return "STT CLI"
        case .sttModel:
            return "STT model"
        }
    }
}

nonisolated struct ComponentRecord: Codable, Equatable, Identifiable {
    var name: ComponentName
    var status: ComponentInstallStatus
    var version: String
    var path: String
    var sourceURL: String
    var sha256: String
    var installedAt: Date?
    var updatedAt: Date
    var lastError: String?

    var id: String {
        name.rawValue
    }
}

nonisolated struct RemoteComponentSpec: Codable, Equatable {
    var name: String?
    var version: String?
    var url: String
    var sha256: String
}

nonisolated struct RemoteComponentManifest: Codable, Equatable {
    var version: String
    var components: [String: RemoteComponentSpec]
}

nonisolated struct ComponentManifest: Codable, Equatable {
    var version: String
    var components: [String: ComponentRecord]
    var installedAt: Date
    var updatedAt: Date

    var backend: ComponentRecord {
        get { components[ComponentName.backend.rawValue] ?? Self.defaultRecord(name: .backend, paths: MwohamPaths()) }
        set { components[ComponentName.backend.rawValue] = newValue }
    }

    var sttCLI: ComponentRecord {
        get { components[ComponentName.sttCLI.rawValue] ?? Self.defaultRecord(name: .sttCLI, paths: MwohamPaths()) }
        set { components[ComponentName.sttCLI.rawValue] = newValue }
    }

    var sttModel: ComponentRecord {
        get { components[ComponentName.sttModel.rawValue] ?? Self.defaultRecord(name: .sttModel, paths: MwohamPaths()) }
        set { components[ComponentName.sttModel.rawValue] = newValue }
    }

    var allRecords: [ComponentRecord] {
        ComponentName.allCases.map { components[$0.rawValue] ?? Self.defaultRecord(name: $0, paths: MwohamPaths()) }
    }

    var allRequiredInstalled: Bool {
        backend.status == .installed
            && sttCLI.status == .installed
            && sttModel.status == .installed
    }

    var backendInstalled: Bool {
        backend.status == .installed
    }

    static func defaultManifest(paths: MwohamPaths, date: Date = Date()) -> Self {
        ComponentManifest(
            version: ComponentInstaller.defaultComponentVersion,
            components: Dictionary(
                uniqueKeysWithValues: ComponentName.allCases.map {
                    ($0.rawValue, defaultRecord(name: $0, paths: paths, date: date))
                }
            ),
            installedAt: date,
            updatedAt: date
        )
    }

    static func defaultRecord(
        name: ComponentName,
        paths: MwohamPaths,
        date: Date = Date()
    ) -> ComponentRecord {
        ComponentRecord(
            name: name,
            status: .missing,
            version: "",
            path: defaultPath(for: name, paths: paths),
            sourceURL: ComponentDownloadConfig.defaultConfig.spec(for: name).url,
            sha256: ComponentDownloadConfig.defaultConfig.spec(for: name).sha256,
            installedAt: nil,
            updatedAt: date,
            lastError: nil
        )
    }

    static func defaultPath(for name: ComponentName, paths: MwohamPaths) -> String {
        switch name {
        case .backend:
            return paths.backendDir.path
        case .sttCLI:
            return paths.sttBinDir
                .appendingPathComponent(STTRuntimeResolver.whisperCLIFileName)
                .path
        case .sttModel:
            return paths.sttModelsDir
                .appendingPathComponent(STTRuntimeResolver.modelFileName)
                .path
        }
    }

    static func loadOrCreate(
        at url: URL,
        paths: MwohamPaths,
        fileManager: FileManager = .default,
        date: Date = Date()
    ) throws -> Self {
        guard fileManager.fileExists(atPath: url.path) else {
            let manifest = defaultManifest(paths: paths, date: date)
            try manifest.write(to: url)
            return manifest
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var manifest = try decoder.decode(ComponentManifest.self, from: data)
            manifest.ensureRecords(paths: paths, date: date)
            return manifest
        } catch {
            let manifest = defaultManifest(paths: paths, date: date)
            try manifest.write(to: url)
            return manifest
        }
    }

    mutating func ensureRecords(paths: MwohamPaths, date: Date = Date()) {
        for name in ComponentName.allCases where components[name.rawValue] == nil {
            components[name.rawValue] = Self.defaultRecord(name: name, paths: paths, date: date)
        }
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

nonisolated struct ComponentDownloadConfig: Equatable {
    static let defaultConfig = ComponentSourceCatalog.v1_1_0

    let version: String
    let baseURLString: String
    var sha256ByComponent: [ComponentName: String] = [:]
    var urlByComponent: [ComponentName: String] = [:]

    func spec(for name: ComponentName) -> RemoteComponentSpec {
        let assetName: String
        switch name {
        case .backend:
            assetName = "MwohamBackend-\(version).tar.gz"
        case .sttCLI:
            assetName = "MwohamSTTRuntime-\(version).tar.gz"
        case .sttModel:
            assetName = STTRuntimeResolver.modelFileName
        }
        return RemoteComponentSpec(
            name: assetName,
            version: version,
            url: urlByComponent[name] ?? "\(baseURLString)/\(assetName)",
            sha256: sha256ByComponent[name] ?? ProcessInfo.processInfo.environment[
                "MWOHAM_\(name.rawValue.uppercased())_SHA256"
            ] ?? ""
        )
    }
}
