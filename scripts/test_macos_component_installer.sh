#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/mac-client/MwohamMac/MwohamMac"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mwoham-component-installer.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

assert_absent_fixed_string() {
  local needle="$1"
  local status
  shift

  grep -F -n -- "$needle" "$@"
  status=$?
  if [[ "$status" -eq 0 ]]; then
    return 1
  fi
  if [[ "$status" -eq 1 ]]; then
    return 0
  fi

  echo "grep failed while checking for: $needle" >&2
  return "$status"
}

cat > "$WORK_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

func writeFile(_ url: URL, text: String = "fixture", executable: Bool = false) {
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
    try! FileManager.default.setAttributes(
        [.posixPermissions: executable ? 0o755 : 0o644],
        ofItemAtPath: url.path
    )
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let resources = root.appendingPathComponent("Resources")
let appSupport = root.appendingPathComponent("Application Support/Mwoham")
let paths = MwohamPaths(appSupportRoot: appSupport)

try paths.ensureDirectories()
expect(FileManager.default.fileExists(atPath: paths.backendDir.deletingLastPathComponent().path), "app support root created")
expect(FileManager.default.fileExists(atPath: paths.sttBinDir.path), "stt bin dir created")
expect(FileManager.default.fileExists(atPath: paths.sttLibDir.path), "stt lib dir created")
expect(FileManager.default.fileExists(atPath: paths.sttModelsDir.path), "stt models dir created")
expect(FileManager.default.fileExists(atPath: paths.logsDir.path), "logs dir created")
expect(FileManager.default.fileExists(atPath: paths.dataDir.path), "data dir created")

let initialManifest = try ComponentManifest.loadOrCreate(
    at: paths.componentManifestPath,
    paths: paths
)
expect(initialManifest.backend.status == .missing, "default backend missing")
expect(initialManifest.sttCLI.status == .missing, "default stt cli missing")
expect(initialManifest.sttModel.status == .missing, "default stt model missing")

var roundTrip = initialManifest
roundTrip.backend.status = .installed
try roundTrip.write(to: paths.componentManifestPath)
let loaded = try ComponentManifest.loadOrCreate(
    at: paths.componentManifestPath,
    paths: paths
)
expect(loaded.backend.status == .installed, "manifest read/write round trip")

let bundledBackendFile = resources
    .appendingPathComponent("backend")
    .appendingPathComponent("app")
    .appendingPathComponent("main.py")
writeFile(bundledBackendFile, text: "print('backend')\n")

let bundledCLI = resources
    .appendingPathComponent("STT")
    .appendingPathComponent("whisper-cli")
writeFile(bundledCLI, text: "#!/bin/sh\nexit 0\n", executable: true)

let installer = ComponentInstaller(
    paths: paths,
    resourceURL: resources
)
let result = try installer.installRequiredComponents()
expect(result.manifest.backend.status == .installed, "backend installed")
expect(FileManager.default.fileExists(atPath: paths.backendDir.appendingPathComponent("app/main.py").path), "backend copied")
expect(result.manifest.sttCLI.status == .installed, "stt cli installed")
expect(FileManager.default.isExecutableFile(atPath: result.manifest.sttCLI.path), "stt cli executable")
expect(result.manifest.sttModel.status == .missing, "stt model missing without bundled model")

let copiedBackendAttributes = try FileManager.default.attributesOfItem(
    atPath: paths.backendDir.appendingPathComponent("app/main.py").path
)
let copiedBackendModifiedAt = copiedBackendAttributes[.modificationDate] as! Date
Thread.sleep(forTimeInterval: 1.0)
let secondResult = try installer.installRequiredComponents()
let secondBackendAttributes = try FileManager.default.attributesOfItem(
    atPath: paths.backendDir.appendingPathComponent("app/main.py").path
)
let secondBackendModifiedAt = secondBackendAttributes[.modificationDate] as! Date
expect(secondResult.manifest.backend.status == .installed, "backend remains installed")
expect(copiedBackendModifiedAt == secondBackendModifiedAt, "installed backend is not recopied")

let bundledModel = resources
    .appendingPathComponent("STT/models")
    .appendingPathComponent(STTRuntimeResolver.modelFileName)
writeFile(bundledModel, text: "model-data")
let repaired = try installer.installRequiredComponents(reinstall: true)
expect(repaired.manifest.sttModel.status == .installed, "stt model installed on repair")
expect(FileManager.default.fileExists(atPath: repaired.manifest.sttModel.path), "stt model copied")

let releaseResolver = STTRuntimeResolver(
    resourceURL: root.appendingPathComponent("empty-resources"),
    applicationSupportURL: root.appendingPathComponent("empty-support"),
    configuredWhisperCLIPath: nil,
    configuredModelPath: nil,
    devWhisperCLIPath: "/Users/a/Projects/mwoham/backend",
    devModelPath: "/Users/a/Projects/mwoham/backend",
    allowsDevFallback: false
)
expect(releaseResolver.resolve().status == .missingWhisperCLI, "dev fallback disabled in release-style resolution")

SWIFT

swiftc \
    -module-cache-path "$WORK_DIR/module-cache" \
    "$WORK_DIR/main.swift" \
    "$APP_DIR/StatusTypes.swift" \
    "$APP_DIR/MwohamPaths.swift" \
    "$APP_DIR/LocalWhisperSettings.swift" \
    "$APP_DIR/STTRuntimeResolver.swift" \
    "$APP_DIR/ComponentManifest.swift" \
    "$APP_DIR/ComponentInstaller.swift" \
    -o "$WORK_DIR/component_installer_harness"

"$WORK_DIR/component_installer_harness" "$WORK_DIR"

if ! assert_absent_fixed_string '"/Users/a/Projects/mwoham/backend"' \
    "$APP_DIR/BackendLifecycleManager.swift" \
    "$APP_DIR/STTRuntimeResolver.swift" \
    "$APP_DIR/MwohamPaths.swift" \
    "$APP_DIR/ComponentInstaller.swift"; then
  echo "Release runtime defaults must not hard-code a developer backend path" >&2
  exit 1
fi

echo "macOS component installer tests passed"
