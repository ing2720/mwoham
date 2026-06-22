#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_SWIFT="$TMP_DIR/TestBackendRuntimeResolver.swift"
COMBINED_SWIFT="$TMP_DIR/CombinedBackendRuntimeResolver.swift"

cat > "$TEST_SWIFT" <<'SWIFT'
import Foundation

func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func makeExecutable(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}

let fileManager = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let home = root.appendingPathComponent("home", isDirectory: true)
let pythonRoot = root.appendingPathComponent("PythonVersions", isDirectory: true)
try fileManager.createDirectory(at: home, withIntermediateDirectories: true)

let restrictedEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
let emptyEnvironment = ["PATH": ""]
let pathBin = root.appendingPathComponent("path-bin", isDirectory: true)
let pathUV = pathBin.appendingPathComponent("uv")
try makeExecutable(pathUV)
let pathResolution = BackendRuntimeResolver.resolveUVExecutable(
    environment: ["PATH": pathBin.path],
    fileManager: fileManager,
    homeDirectory: home,
    pythonVersionsRoot: pythonRoot
)
assert(
    pathResolution.executablePath == pathUV.path,
    "process PATH uv should be resolved before common candidates"
)

let homeUV = home.appendingPathComponent(".local/bin/uv")
try makeExecutable(homeUV)

let homeResolution = BackendRuntimeResolver.resolveUVExecutable(
    environment: emptyEnvironment,
    fileManager: fileManager,
    homeDirectory: home,
    pythonVersionsRoot: pythonRoot
)
assert(
    homeResolution.executablePath != nil,
    "empty PATH should still resolve uv from common candidates when available"
)
assert(
    homeResolution.candidatePaths.contains(homeUV.path),
    "candidate list should include HOME .local uv"
)
let restrictedCandidates = BackendRuntimeResolver.uvCandidatePaths(
    environment: restrictedEnvironment,
    homeDirectory: home,
    pythonVersionsRoot: pythonRoot,
    fileManager: fileManager
)
assert(
    restrictedCandidates.contains("/opt/homebrew/bin/uv"),
    "candidate list should include /opt/homebrew/bin/uv"
)
assert(
    restrictedCandidates.contains("/usr/local/bin/uv"),
    "candidate list should include /usr/local/bin/uv"
)

try fileManager.removeItem(at: homeUV)
let pythonUV = pythonRoot
    .appendingPathComponent("3.14", isDirectory: true)
    .appendingPathComponent("bin", isDirectory: true)
    .appendingPathComponent("uv")
try makeExecutable(pythonUV)

let pythonResolution = BackendRuntimeResolver.resolveUVExecutable(
    environment: restrictedEnvironment,
    fileManager: fileManager,
    homeDirectory: home,
    pythonVersionsRoot: pythonRoot
)
assert(
    pythonResolution.executablePath != nil,
    "restricted PATH should resolve uv from PATH or common candidates when available"
)
assert(
    pythonResolution.candidatePaths
        .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        .contains(pythonUV.standardizedFileURL.path),
    "candidate list should include Python framework version uv"
)

let extendedPath = BackendRuntimeResolver.extendedPath(
    resolvedUVPath: pythonUV.path,
    existingPath: restrictedEnvironment["PATH"],
    homeDirectory: home
)
assert(
    extendedPath.split(separator: ":").first == Substring(pythonUV.deletingLastPathComponent().path),
    "resolved uv parent should be first PATH entry"
)
assert(
    extendedPath.contains("/opt/homebrew/bin"),
    "extended PATH should include Homebrew on Apple Silicon"
)

let backend = root.appendingPathComponent("backend", isDirectory: true)
let venvBin = backend
    .appendingPathComponent(".venv", isDirectory: true)
    .appendingPathComponent("bin", isDirectory: true)
let venvAlembic = venvBin.appendingPathComponent("alembic")
let venvPython = venvBin.appendingPathComponent("python")
try makeExecutable(venvAlembic)
try makeExecutable(venvPython)

let migrationCommand = BackendRuntimeResolver.migrationCommand(
    backendDirectory: backend,
    uvExecutablePath: nil,
    fileManager: fileManager
)
assert(
    migrationCommand?.executableURL.path == venvAlembic.path,
    ".venv alembic should be used without uv"
)
assert(
    migrationCommand?.arguments == ["upgrade", "head"],
    ".venv alembic arguments should run migration directly"
)

let backendCommand = BackendRuntimeResolver.backendCommand(
    backendDirectory: backend,
    uvExecutablePath: nil,
    fileManager: fileManager
)
assert(
    backendCommand?.executableURL.path == venvPython.path,
    ".venv python should be used without uv"
)
assert(
    backendCommand?.arguments.prefix(3) == ["-m", "uvicorn", "app.main:app"],
    ".venv python should launch uvicorn module"
)

try fileManager.removeItem(at: backend.appendingPathComponent(".venv", isDirectory: true))
let uvMigrationCommand = BackendRuntimeResolver.migrationCommand(
    backendDirectory: backend,
    uvExecutablePath: pythonUV.path,
    fileManager: fileManager
)
assert(
    uvMigrationCommand?.executableURL.path == pythonUV.path,
    "uv fallback should use resolved absolute uv path"
)
assert(
    uvMigrationCommand?.arguments == ["run", "alembic", "upgrade", "head"],
    "uv fallback migration arguments should use uv run"
)

let diagnostic = BackendRuntimeResolver.missingUVDiagnostic(
    BackendUVResolution(
        executablePath: nil,
        candidatePaths: ["/opt/homebrew/bin/uv"],
        pathEnvironment: "/usr/bin:/bin"
    )
)
assert(diagnostic.contains("현재 PATH"), "diagnostic should include current PATH")
assert(diagnostic.contains("brew install uv"), "diagnostic should include Homebrew install command")
assert(diagnostic.contains("astral.sh/uv"), "diagnostic should include official installer command")

print("BackendRuntimeResolver tests passed")
SWIFT

cat "$ROOT_DIR/mac-client/MwohamMac/MwohamMac/BackendRuntimeResolver.swift" "$TEST_SWIFT" > "$COMBINED_SWIFT"
CLANG_MODULE_CACHE_PATH="$TMP_DIR/module-cache" swift "$COMBINED_SWIFT" "$TMP_DIR"
