//
//  MwohamPaths.swift
//  MwohamMac
//

import Foundation

nonisolated struct MwohamPaths: Equatable {
    let appSupportRoot: URL

    var backendDir: URL {
        appSupportRoot.appendingPathComponent("backend", isDirectory: true)
    }

    var sttRoot: URL {
        appSupportRoot.appendingPathComponent("stt", isDirectory: true)
    }

    var sttBinDir: URL {
        sttRoot.appendingPathComponent("bin", isDirectory: true)
    }

    var sttLibDir: URL {
        sttRoot.appendingPathComponent("lib", isDirectory: true)
    }

    var sttModelsDir: URL {
        sttRoot.appendingPathComponent("models", isDirectory: true)
    }

    var logsDir: URL {
        appSupportRoot.appendingPathComponent("logs", isDirectory: true)
    }

    var dataDir: URL {
        appSupportRoot.appendingPathComponent("data", isDirectory: true)
    }

    var componentManifestPath: URL {
        appSupportRoot.appendingPathComponent("component_manifest.json")
    }

    init(appSupportRoot: URL = Self.defaultAppSupportRoot()) {
        self.appSupportRoot = appSupportRoot
    }

    func ensureDirectories(fileManager: FileManager = .default) throws {
        for directory in [
            appSupportRoot,
            sttRoot,
            sttBinDir,
            sttLibDir,
            sttModelsDir,
            logsDir,
            dataDir,
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    static func defaultAppSupportRoot(
        fileManager: FileManager = .default
    ) -> URL {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return baseURL.appendingPathComponent("Mwoham", isDirectory: true)
    }
}
