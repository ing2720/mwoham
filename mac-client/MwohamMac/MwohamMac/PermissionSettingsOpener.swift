//
//  PermissionSettingsOpener.swift
//  MwohamMac
//

import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import Speech

@MainActor
enum PermissionSettingsOpener {
    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            openMicrophoneSettings()
            return false
        @unknown default:
            openMicrophoneSettings()
            return false
        }
    }

    static func requestSpeechRecognitionAccess() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            if status != .authorized {
                openSpeechRecognitionSettings()
            }
            return status == .authorized
        case .denied, .restricted:
            openSpeechRecognitionSettings()
            return false
        @unknown default:
            openSpeechRecognitionSettings()
            return false
        }
    }

    static func requestScreenRecordingAccess() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else {
            return true
        }
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            openScreenRecordingSettings()
        }
        return granted
    }

    static func requestAccessibilityAccess() -> Bool {
        guard !AXIsProcessTrusted() else {
            return true
        }
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            openAccessibilitySettings()
        }
        return trusted
    }

    static func openMicrophoneSettings() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    static func openSpeechRecognitionSettings() {
        openPrivacySettings(anchor: "Privacy_SpeechRecognition")
    }

    static func openScreenRecordingSettings() {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    private static func openPrivacySettings(anchor: String) {
        let urlStrings = [
            "x-apple.systempreferences:com.apple.SystemSettings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
        ]
        openSettingsURLs(urlStrings)
    }

    private static func openSettingsURLs(_ urlStrings: [String]) {
        let urls = urlStrings.compactMap(URL.init(string:))
        guard let firstURL = urls.first else {
            return
        }

        openSettingsURL(firstURL)

        for (offset, url) in urls.dropFirst().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250 * (offset + 1))) {
                openSettingsURL(url)
            }
        }
    }

    private static func openSettingsURL(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration)
    }
}
