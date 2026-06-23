#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/mac-client/MwohamMac/MwohamMac"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mwoham-component-installer.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

ASSET_DIR="$WORK_DIR/assets"
BACKEND_SRC="$WORK_DIR/backend-src"
STT_SRC="$WORK_DIR/stt-src"
MODEL_SRC="$ASSET_DIR/ggml-large-v3-turbo.bin"
mkdir -p "$ASSET_DIR" "$BACKEND_SRC/alembic" "$BACKEND_SRC/app" "$STT_SRC/bin" "$STT_SRC/lib"

printf '[project]\nname = "mwoham-backend"\n' > "$BACKEND_SRC/pyproject.toml"
printf 'version = 1\n' > "$BACKEND_SRC/uv.lock"
printf '[alembic]\n' > "$BACKEND_SRC/alembic.ini"
printf '# migration\n' > "$BACKEND_SRC/alembic/env.py"
printf '# app\n' > "$BACKEND_SRC/app/main.py"

printf '#!/bin/sh\nexit 0\n' > "$STT_SRC/bin/whisper-cli"
chmod +x "$STT_SRC/bin/whisper-cli"
for dylib in libwhisper.1.dylib libggml.0.dylib libggml-base.0.dylib libomp.dylib; do
  printf 'fixture-%s\n' "$dylib" > "$STT_SRC/lib/$dylib"
done

tar -czf "$ASSET_DIR/MwohamBackend-1.1.0.tar.gz" -C "$BACKEND_SRC" .
tar -czf "$ASSET_DIR/MwohamSTTRuntime-1.1.0.tar.gz" -C "$STT_SRC" .
mkfile -n 101m "$MODEL_SRC"

BACKEND_SHA="$(shasum -a 256 "$ASSET_DIR/MwohamBackend-1.1.0.tar.gz" | awk '{print $1}')"
STTCLI_SHA="$(shasum -a 256 "$ASSET_DIR/MwohamSTTRuntime-1.1.0.tar.gz" | awk '{print $1}')"
MODEL_SHA="$(shasum -a 256 "$MODEL_SRC" | awk '{print $1}')"

cat > "$WORK_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let assetBaseURL = CommandLine.arguments[2]
let backendSHA = CommandLine.arguments[3]
let sttCLISHA = CommandLine.arguments[4]
let modelSHA = CommandLine.arguments[5]
let appSupport = root.appendingPathComponent("Application Support/Mwoham")
let paths = MwohamPaths(appSupportRoot: appSupport)
let config = ComponentDownloadConfig(
    version: "1.1.0",
    baseURLString: assetBaseURL,
    sha256ByComponent: [
        .backend: backendSHA,
        .sttCLI: sttCLISHA,
        .sttModel: modelSHA,
    ]
)
let installer = ComponentInstaller(paths: paths, resourceURL: nil, downloadConfig: config)

let missing = try installer.refreshInstalledComponents()
expect(missing.manifest.backend.status == .missing, "backend missing in lightweight clean install")
expect(missing.manifest.sttCLI.status == .missing, "stt cli missing in lightweight clean install")
expect(missing.manifest.sttModel.status == .missing, "stt model missing in lightweight clean install")
expect(
    config.spec(for: .backend).url.hasSuffix("/MwohamBackend-1.1.0.tar.gz"),
    "backend download URL resolves release asset name"
)
expect(
    config.spec(for: .sttCLI).url.hasSuffix("/MwohamSTTRuntime-1.1.0.tar.gz"),
    "stt cli download URL resolves release asset name"
)
expect(config.spec(for: .backend).sha256 == backendSHA, "fixture backend sha is explicit")
expect(config.spec(for: .sttModel).sha256 == modelSHA, "fixture model sha is explicit")

let noChecksumConfig = ComponentDownloadConfig(version: "1.1.0", baseURLString: assetBaseURL)
let noChecksumInstaller = ComponentInstaller(
    paths: MwohamPaths(appSupportRoot: root.appendingPathComponent("no-checksum-support")),
    resourceURL: nil,
    downloadConfig: noChecksumConfig
)
do {
    _ = try await noChecksumInstaller.installDownloadedComponents([.backend])
    fatalError("missing checksum should fail")
} catch {
    expect(
        error.localizedDescription.contains("릴리즈 asset manifest"),
        "missing checksum message points to release asset manifest"
    )
}

var progressEvents: [ComponentInstallProgress] = []
let backendOnly = try await installer.installDownloadedComponents(
    [.backend],
    onProgress: { progress in
        progressEvents.append(progress)
    }
)
expect(backendOnly.manifest.backend.status == .installed, "backend installed from archive")
expect(FileManager.default.fileExists(atPath: paths.backendDir.appendingPathComponent("pyproject.toml").path), "backend pyproject installed")
expect(FileManager.default.fileExists(atPath: paths.backendDir.appendingPathComponent("app/main.py").path), "backend app installed")
expect(backendOnly.manifest.sttModel.status == .missing, "stt model can remain missing while backend is installed")
expect(progressEvents.contains { $0.component == .backend && $0.phase == .downloading }, "backend download progress is reported")
expect(progressEvents.contains { $0.component == .backend && $0.phase == .verifying }, "backend verify progress is reported")
expect(progressEvents.contains { $0.component == .backend && $0.phase == .installing }, "backend install progress is reported")
expect(progressEvents.contains { $0.component == .backend && $0.phase == .completed }, "backend completion progress is reported")

let backendModifiedAt = try FileManager.default.attributesOfItem(
    atPath: paths.backendDir.appendingPathComponent("pyproject.toml").path
)[.modificationDate] as! Date
try await Task.sleep(nanoseconds: 1_000_000_000)
let skipped = try await installer.installDownloadedComponents([.backend])
let skippedModifiedAt = try FileManager.default.attributesOfItem(
    atPath: paths.backendDir.appendingPathComponent("pyproject.toml").path
)[.modificationDate] as! Date
expect(skipped.manifest.backend.status == .installed, "installed backend stays installed")
expect(backendModifiedAt == skippedModifiedAt, "already installed backend is not downloaded/reinstalled")

let stt = try await installer.installDownloadedComponents([.sttCLI])
expect(stt.manifest.sttCLI.status == .installed, "stt cli installed from archive")
expect(FileManager.default.isExecutableFile(atPath: paths.sttBinDir.appendingPathComponent("whisper-cli").path), "stt cli executable")
expect(FileManager.default.fileExists(atPath: paths.sttLibDir.appendingPathComponent("libomp.dylib").path), "stt libs installed")

let model = try await installer.installDownloadedComponents([.sttModel])
expect(model.manifest.sttModel.status == .installed, "stt model installed")
expect(FileManager.default.fileExists(atPath: paths.sttModelsDir.appendingPathComponent(STTRuntimeResolver.modelFileName).path), "stt model final path exists")

let badConfig = ComponentDownloadConfig(
    version: "1.1.0",
    baseURLString: assetBaseURL,
    sha256ByComponent: [.backend: "0000"]
)
let badInstaller = ComponentInstaller(
    paths: MwohamPaths(appSupportRoot: root.appendingPathComponent("bad-support")),
    resourceURL: nil,
    downloadConfig: badConfig
)
do {
    _ = try await badInstaller.installDownloadedComponents([.backend])
    fatalError("checksum mismatch should fail")
} catch {
    expect(error.localizedDescription.contains("checksum mismatch"), "checksum mismatch is reported")
}

print("macOS component installer tests passed")
SWIFT

swiftc \
  -module-cache-path "$WORK_DIR/module-cache" \
  "$WORK_DIR/main.swift" \
  "$APP_DIR/StatusTypes.swift" \
  "$APP_DIR/MwohamPaths.swift" \
  "$APP_DIR/LocalWhisperSettings.swift" \
  "$APP_DIR/STTRuntimeResolver.swift" \
  "$APP_DIR/GeneratedComponentSources.swift" \
  "$APP_DIR/ComponentManifest.swift" \
  "$APP_DIR/ComponentInstaller.swift" \
  -o "$WORK_DIR/component_installer_harness"

"$WORK_DIR/component_installer_harness" "$WORK_DIR" "file://$ASSET_DIR" "$BACKEND_SHA" "$STTCLI_SHA" "$MODEL_SHA"

echo "macOS component installer tests passed"
