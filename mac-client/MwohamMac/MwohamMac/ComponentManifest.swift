//
//  ComponentManifest.swift
//  MwohamMac
//

import Foundation

nonisolated enum ComponentInstallStatus: String, Codable, Equatable {
    case missing
    case installed
    case invalid
}

nonisolated struct ComponentManifest: Codable, Equatable {
    struct Backend: Codable, Equatable {
        var version: String
        var path: String
        var status: ComponentInstallStatus
    }

    struct STTCLI: Codable, Equatable {
        var version: String
        var path: String
        var status: ComponentInstallStatus
    }

    struct STTModel: Codable, Equatable {
        var name: String
        var path: String
        var status: ComponentInstallStatus
    }

    var backend: Backend
    var sttCLI: STTCLI
    var sttModel: STTModel
    var installedAt: Date
    var updatedAt: Date

    static func defaultManifest(paths: MwohamPaths, date: Date = Date()) -> Self {
        ComponentManifest(
            backend: Backend(
                version: "",
                path: paths.backendDir.path,
                status: .missing
            ),
            sttCLI: STTCLI(
                version: "",
                path: paths.sttBinDir
                    .appendingPathComponent(STTRuntimeResolver.whisperCLIFileName)
                    .path,
                status: .missing
            ),
            sttModel: STTModel(
                name: STTRuntimeResolver.modelFileName,
                path: paths.sttModelsDir
                    .appendingPathComponent(STTRuntimeResolver.modelFileName)
                    .path,
                status: .missing
            ),
            installedAt: date,
            updatedAt: date
        )
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

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ComponentManifest.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
