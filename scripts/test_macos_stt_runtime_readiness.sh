#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/mac-client/MwohamMac/MwohamMac"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mwoham-stt-runtime.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

func writeFile(_ url: URL, executable: Bool = false) {
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: url.path, contents: Data("fixture".utf8))
    if executable {
        try! FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    } else {
        try! FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let bundledRoot = root.appendingPathComponent("bundle")
let appSupportRoot = root.appendingPathComponent("Application Support/Mwoham")
let devRoot = root.appendingPathComponent("dev")

let bundledCLI = bundledRoot
    .appendingPathComponent("STT")
    .appendingPathComponent("whisper-cli")
let bundledModel = bundledRoot
    .appendingPathComponent("STT/models")
    .appendingPathComponent("ggml-large-v3-turbo.bin")
let appSupportCLI = appSupportRoot
    .appendingPathComponent("stt")
    .appendingPathComponent("whisper-cli")
let appSupportModel = appSupportRoot
    .appendingPathComponent("models")
    .appendingPathComponent("ggml-large-v3-turbo.bin")
let devCLI = devRoot.appendingPathComponent("whisper-cli")
let devModel = devRoot.appendingPathComponent("ggml-large-v3-turbo.bin")

writeFile(bundledCLI, executable: true)
writeFile(bundledModel)

var readiness = STTRuntimeResolver(
    resourceURL: bundledRoot,
    applicationSupportURL: appSupportRoot,
    configuredWhisperCLIPath: nil,
    configuredModelPath: nil,
    devWhisperCLIPath: nil,
    devModelPath: nil,
    allowsDevFallback: false
).resolve()
expect(readiness.status == .ready, "bundled runtime and model should be ready")
expect(readiness.whisperCLI.source == .bundled, "bundled CLI should win")
expect(readiness.model.source == .bundled, "bundled model should win")
expect(readiness.configuration?.language == "ko", "runtime uses Korean model language")

let missingCLIReadiness = STTRuntimeResolver(
    resourceURL: root.appendingPathComponent("missing-cli-bundle"),
    applicationSupportURL: root.appendingPathComponent("missing-cli-support"),
    configuredWhisperCLIPath: nil,
    configuredModelPath: bundledModel.path,
    devWhisperCLIPath: nil,
    devModelPath: nil,
    allowsDevFallback: false
).resolve()
expect(missingCLIReadiness.status == .missingWhisperCLI, "missing CLI should block STT")

let missingModelReadiness = STTRuntimeResolver(
    resourceURL: root.appendingPathComponent("missing-model-bundle"),
    applicationSupportURL: root.appendingPathComponent("missing-model-support"),
    configuredWhisperCLIPath: bundledCLI.path,
    configuredModelPath: nil,
    devWhisperCLIPath: nil,
    devModelPath: nil,
    allowsDevFallback: false
).resolve()
expect(missingModelReadiness.status == .missingModel, "missing model should block STT")

let nonExecutableCLI = root.appendingPathComponent("not-executable/whisper-cli")
writeFile(nonExecutableCLI, executable: false)
let nonExecutableReadiness = STTRuntimeResolver(
    resourceURL: root.appendingPathComponent("not-executable-bundle"),
    applicationSupportURL: root.appendingPathComponent("not-executable-support"),
    configuredWhisperCLIPath: nonExecutableCLI.path,
    configuredModelPath: bundledModel.path,
    devWhisperCLIPath: nil,
    devModelPath: nil,
    allowsDevFallback: false
).resolve()
expect(
    nonExecutableReadiness.status == .whisperCLINotExecutable,
    "non-executable CLI should be reported clearly"
)

writeFile(appSupportCLI, executable: true)
writeFile(appSupportModel)
readiness = STTRuntimeResolver(
    resourceURL: root.appendingPathComponent("fallback-empty-bundle"),
    applicationSupportURL: appSupportRoot,
    configuredWhisperCLIPath: nil,
    configuredModelPath: nil,
    devWhisperCLIPath: nil,
    devModelPath: nil,
    allowsDevFallback: false
).resolve()
expect(readiness.status == .ready, "Application Support fallback should be ready")
expect(readiness.whisperCLI.source == .applicationSupport, "Application Support CLI source")
expect(readiness.model.source == .applicationSupport, "Application Support model source")

writeFile(devCLI, executable: true)
writeFile(devModel)
let devDisabled = STTRuntimeResolver(
    resourceURL: root.appendingPathComponent("dev-disabled-bundle"),
    applicationSupportURL: root.appendingPathComponent("dev-disabled-support"),
    configuredWhisperCLIPath: nil,
    configuredModelPath: nil,
    devWhisperCLIPath: devCLI.path,
    devModelPath: devModel.path,
    allowsDevFallback: false
).resolve()
expect(devDisabled.status == .missingWhisperCLI, "dev fallback should not be used when disabled")

let devEnabled = STTRuntimeResolver(
    resourceURL: root.appendingPathComponent("dev-enabled-bundle"),
    applicationSupportURL: root.appendingPathComponent("dev-enabled-support"),
    configuredWhisperCLIPath: nil,
    configuredModelPath: nil,
    devWhisperCLIPath: devCLI.path,
    devModelPath: devModel.path,
    allowsDevFallback: true
).resolve()
expect(devEnabled.status == .ready, "dev fallback should be available in dev mode")
expect(devEnabled.whisperCLI.source == .devFallback, "dev CLI source is explicit")
expect(devEnabled.model.source == .devFallback, "dev model source is explicit")

let env = STTRuntimeResolver(
    resourceURL: bundledRoot,
    applicationSupportURL: appSupportRoot,
    configuredWhisperCLIPath: nil,
    configuredModelPath: nil,
    devWhisperCLIPath: nil,
    devModelPath: nil,
    allowsDevFallback: false
).backendEnvironmentValues()
expect(env["STT_WHISPER_CLI_PATH"] == bundledCLI.path, "backend env includes CLI path")
expect(env["STT_MODEL_PATH"] == bundledModel.path, "backend env includes model path")

print("macOS STT runtime readiness tests passed")
SWIFT

swiftc \
    -module-cache-path "$WORK_DIR/module-cache" \
    "$WORK_DIR/main.swift" \
    "$APP_DIR/StatusTypes.swift" \
    "$APP_DIR/LocalWhisperSettings.swift" \
    "$APP_DIR/STTRuntimeResolver.swift" \
    -o "$WORK_DIR/stt_runtime_readiness_harness"

"$WORK_DIR/stt_runtime_readiness_harness" "$WORK_DIR"

if rg -n '"/Users/a/Library/Application Support/Mwoham/models/ggml-large-v3-turbo.bin"' \
    "$APP_DIR/STTRuntimeResolver.swift" "$APP_DIR/LocalWhisperSettings.swift"; then
  echo "user-specific model path must not be a production default" >&2
  exit 1
fi
