//
//  BackendRuntimeResolver.swift
//  MwohamMac
//

import Foundation

nonisolated struct BackendUVResolution: Equatable, Sendable {
    let executablePath: String?
    let candidatePaths: [String]
    let pathEnvironment: String

    var displayPath: String {
        executablePath ?? "uv missing"
    }
}

nonisolated struct BackendRuntimeCommand: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let display: String
}

nonisolated enum BackendRuntimeResolver {
    static func resolveUVExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pythonVersionsRoot: URL = URL(
            fileURLWithPath: "/Library/Frameworks/Python.framework/Versions",
            isDirectory: true
        )
    ) -> BackendUVResolution {
        let candidates = uvCandidatePaths(
            environment: environment,
            homeDirectory: homeDirectory,
            pythonVersionsRoot: pythonVersionsRoot,
            fileManager: fileManager
        )
        let resolved = candidates.first {
            fileManager.isExecutableFile(atPath: $0)
        }
        return BackendUVResolution(
            executablePath: resolved,
            candidatePaths: candidates,
            pathEnvironment: environment["PATH"] ?? ""
        )
    }

    static func uvCandidatePaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pythonVersionsRoot: URL = URL(
            fileURLWithPath: "/Library/Frameworks/Python.framework/Versions",
            isDirectory: true
        ),
        fileManager: FileManager = .default
    ) -> [String] {
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("uv").path }

        let commonCandidates = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            homeDirectory
                .appendingPathComponent(".local/bin/uv")
                .path,
            homeDirectory
                .appendingPathComponent(".cargo/bin/uv")
                .path,
            "/Library/Frameworks/Python.framework/Versions/Current/bin/uv",
        ]

        let versionCandidates = pythonVersionUVPaths(
            versionsRoot: pythonVersionsRoot,
            fileManager: fileManager
        )

        return deduplicate(pathCandidates + commonCandidates + versionCandidates)
    }

    static func extendedPath(
        resolvedUVPath: String?,
        existingPath: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        var directories: [String] = []
        if let resolvedUVPath {
            directories.append(
                URL(fileURLWithPath: resolvedUVPath)
                    .deletingLastPathComponent()
                    .path
            )
        }
        directories.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent(".cargo/bin").path,
            "/Library/Frameworks/Python.framework/Versions/Current/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ])
        if let existingPath, !existingPath.isEmpty {
            directories.append(contentsOf: existingPath.split(separator: ":").map(String.init))
        }
        return deduplicate(directories).joined(separator: ":")
    }

    static func migrationCommand(
        backendDirectory: URL,
        uvExecutablePath: String?,
        fileManager: FileManager = .default
    ) -> BackendRuntimeCommand? {
        let venvAlembic = backendDirectory
            .appendingPathComponent(".venv", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("alembic")
        if fileManager.isExecutableFile(atPath: venvAlembic.path) {
            return BackendRuntimeCommand(
                executableURL: venvAlembic,
                arguments: ["upgrade", "head"],
                display: "./.venv/bin/alembic upgrade head"
            )
        }

        guard let uvExecutablePath else {
            return nil
        }
        return BackendRuntimeCommand(
            executableURL: URL(fileURLWithPath: uvExecutablePath),
            arguments: ["run", "alembic", "upgrade", "head"],
            display: "\(uvExecutablePath) run alembic upgrade head"
        )
    }

    static func backendCommand(
        backendDirectory: URL,
        uvExecutablePath: String?,
        fileManager: FileManager = .default
    ) -> BackendRuntimeCommand? {
        let venvPython = backendDirectory
            .appendingPathComponent(".venv", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python")
        if fileManager.isExecutableFile(atPath: venvPython.path) {
            return BackendRuntimeCommand(
                executableURL: venvPython,
                arguments: [
                    "-m",
                    "uvicorn",
                    "app.main:app",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    "8765",
                    "--reload",
                ],
                display: "./.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload"
            )
        }

        guard let uvExecutablePath else {
            return nil
        }
        return BackendRuntimeCommand(
            executableURL: URL(fileURLWithPath: uvExecutablePath),
            arguments: [
                "run",
                "uvicorn",
                "app.main:app",
                "--host",
                "127.0.0.1",
                "--port",
                "8765",
                "--reload",
            ],
            display: "\(uvExecutablePath) run uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload"
        )
    }

    static func missingUVDiagnostic(_ resolution: BackendUVResolution) -> String {
        let candidates = resolution.candidatePaths
            .map { "  - \($0)" }
            .joined(separator: "\n")
        return """
        uv 실행 파일을 찾을 수 없습니다.
        현재 PATH: \(resolution.pathEnvironment.isEmpty ? "(empty)" : resolution.pathEnvironment)
        확인한 uv 후보 경로:
        \(candidates)
        해결 방법:
          brew install uv
          또는 curl -LsSf https://astral.sh/uv/install.sh | sh
        """
    }

    private static func pythonVersionUVPaths(
        versionsRoot: URL,
        fileManager: FileManager
    ) -> [String] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: versionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents
            .filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(
                    atPath: url.path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
                    && url.lastPathComponent != "Current"
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map {
                $0.appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent("uv")
                    .path
            }
    }

    private static func deduplicate(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            seen.insert(value).inserted
        }
    }
}
