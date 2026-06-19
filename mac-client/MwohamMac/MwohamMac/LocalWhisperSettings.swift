//
//  LocalWhisperSettings.swift
//  MwohamMac
//

import Foundation

struct LocalWhisperConfiguration: Sendable {
    let binaryURL: URL
    let modelURL: URL
    let language: String
}

enum LocalWhisperConfigurationResolution {
    case available(LocalWhisperConfiguration)
    case unavailable(String)
}

enum LocalWhisperSettings {
    static let binaryPathKey = "localWhisperBinaryPath"
    static let modelPathKey = "localWhisperModelPath"
    static let debugAudioExportEnabledKey = "localWhisperDebugAudioExportEnabled"

    static func resolve(
        defaults: UserDefaults = .standard
    ) -> LocalWhisperConfigurationResolution {
        let readiness = STTRuntimeResolver(
            configuredWhisperCLIPath: defaults.string(forKey: binaryPathKey),
            configuredModelPath: defaults.string(forKey: modelPathKey)
        ).resolve()
        guard let configuration = readiness.configuration else {
            return .unavailable(readiness.status.detail)
        }
        return .available(configuration)
    }
}
