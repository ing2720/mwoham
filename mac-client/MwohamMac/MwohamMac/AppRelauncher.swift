//
//  AppRelauncher.swift
//  MwohamMac
//

import AppKit
import Foundation

enum AppRelauncher {
    @MainActor
    static func relaunch(
        bundleURL: URL = Bundle.main.bundleURL,
        delaySeconds: Double = 0.4,
        currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        do {
            try launchRelaunchHelper(
                bundleURL: bundleURL,
                delaySeconds: delaySeconds,
                currentProcessID: currentProcessID
            )
            NSApplication.shared.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "앱 다시시작 실패"
            alert.informativeText =
                "앱을 자동으로 다시 열 수 없습니다. 앱을 직접 다시 실행해 주세요.\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
    }

    nonisolated static func launchRelaunchHelper(
        bundleURL: URL,
        delaySeconds: Double = 0.4,
        currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            relaunchCommand(
                bundlePath: bundleURL.path,
                delaySeconds: delaySeconds,
                currentProcessID: currentProcessID
            ),
        ]
        try process.run()
    }

    nonisolated static func relaunchCommand(
        bundlePath: String,
        delaySeconds: Double = 0.4,
        currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> String {
        [
            "i=0",
            "while /bin/kill -0 \(currentProcessID) 2>/dev/null && [ $i -lt 80 ]",
            "do /bin/sleep 0.1; i=$((i + 1)); done",
            "/bin/sleep \(delayText(delaySeconds))",
            "/usr/bin/open -n \(shellQuoted(bundlePath))",
        ].joined(separator: "; ")
    }

    nonisolated private static func delayText(_ delaySeconds: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        return formatter.string(from: NSNumber(value: delaySeconds)) ?? "0.4"
    }

    nonisolated private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
