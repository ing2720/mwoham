//
//  DevTrackingProcessController.swift
//  MwohamMac
//

import AppKit
import Foundation

@MainActor
final class DevTrackingProcessController {
    private let backendPath: URL
    private let repoPath: String
    private let intervalSeconds: Int
    private let gracePeriodSeconds: TimeInterval
    private let debounceSeconds: TimeInterval
    private var process: Process?
    private var stopTask: Task<Void, Never>?
    private var lastStartAttemptAt: Date?
    private var terminationObserver: NSObjectProtocol?
    private var lastErrorOutput = ""

    init(
        backendPath: URL = DevTrackingProcessController.defaultBackendPath(),
        repoPath: String = "..",
        intervalSeconds: Int = 60,
        gracePeriodSeconds: TimeInterval = 120,
        debounceSeconds: TimeInterval = 10
    ) {
        self.backendPath = backendPath
        self.repoPath = repoPath
        self.intervalSeconds = intervalSeconds
        self.gracePeriodSeconds = gracePeriodSeconds
        self.debounceSeconds = debounceSeconds
        self.terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func handleActiveApplication(_ appName: String, onStatusChange: @escaping (String) -> Void) {
        guard isDevelopmentTool(appName) else {
            scheduleStop(onStatusChange: onStatusChange)
            return
        }

        stopTask?.cancel()
        stopTask = nil

        if isRunning {
            onStatusChange("Dev Tracking: 개발 도구 감지됨, 감시 중")
            return
        }

        start(onStatusChange: onStatusChange)
    }

    func stop(onStatusChange: ((String) -> Void)? = nil) {
        stopTask?.cancel()
        stopTask = nil

        guard let process else {
            onStatusChange?("Dev Tracking: 종료됨")
            return
        }

        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        onStatusChange?("Dev Tracking: 종료됨")
    }

    private func start(onStatusChange: @escaping (String) -> Void) {
        if let lastStartAttemptAt,
           Date().timeIntervalSince(lastStartAttemptAt) < debounceSeconds {
            onStatusChange("Dev Tracking: 개발 도구 감지됨, 시작 대기 중")
            return
        }

        lastStartAttemptAt = Date()

        guard FileManager.default.fileExists(atPath: backendPath.path) else {
            onStatusChange("Dev Tracking 오류: backend 경로를 찾을 수 없습니다.")
            return
        }

        let process = Process()
        let standardError = Pipe()
        process.currentDirectoryURL = backendPath
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "uv",
            "run",
            "python",
            "scripts/watch_dev_context.py",
            "--repo-path",
            repoPath,
            "--interval",
            "\(intervalSeconds)",
            "--session-current",
        ]
        process.environment = processEnvironment()
        process.standardOutput = Pipe()
        process.standardError = standardError
        standardError.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.lastErrorOutput = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        process.terminationHandler = { [weak self, weak process] terminatedProcess in
            Task { @MainActor [weak self, weak process] in
                guard let self, let process, process === terminatedProcess else {
                    return
                }
                standardError.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                if terminatedProcess.terminationStatus == 0 {
                    onStatusChange("Dev Tracking: 종료됨")
                } else {
                    let detail = self.lastErrorOutput.isEmpty ? "" : " - \(self.lastErrorOutput)"
                    onStatusChange(
                        "Dev Tracking 오류: watcher 종료 코드 \(terminatedProcess.terminationStatus)\(detail)"
                    )
                }
            }
        }

        do {
            try process.run()
            self.process = process
            onStatusChange("Dev Tracking: 개발 도구 감지됨, 감시 중")
        } catch {
            onStatusChange("Dev Tracking 오류: \(error.localizedDescription)")
        }
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let pathCandidates = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = (pathCandidates + [existingPath])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        environment["UV_CACHE_DIR"] = environment["UV_CACHE_DIR"] ?? "/private/tmp/mwoham-uv-cache"
        return environment
    }

    private func scheduleStop(onStatusChange: @escaping (String) -> Void) {
        guard isRunning else {
            onStatusChange("Dev Tracking: 대기 중")
            return
        }

        if stopTask != nil {
            onStatusChange("Dev Tracking: 비개발 앱 감지, 종료 대기 중")
            return
        }

        onStatusChange("Dev Tracking: 비개발 앱 감지, 종료 대기 중")
        stopTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(gracePeriodSeconds * 1_000_000_000))
            } catch {
                return
            }

            await MainActor.run {
                self.stop(onStatusChange: onStatusChange)
            }
        }
    }

    private func isDevelopmentTool(_ appName: String) -> Bool {
        let normalized = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exactMatches = [
            "pycharm",
            "visual studio code",
            "code",
            "terminal",
            "iterm",
            "iterm2",
            "cursor",
        ]
        return exactMatches.contains(normalized)
            || normalized.contains("pycharm")
            || normalized.contains("visual studio code")
            || normalized.contains("iterm")
    }

    nonisolated private static func defaultBackendPath(filePath: String = #filePath) -> URL {
        let sourceFile = URL(fileURLWithPath: filePath)
        let repoRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let backendPath = repoRoot.appendingPathComponent("backend")
        if FileManager.default.fileExists(atPath: backendPath.path) {
            return backendPath
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let currentBackend = currentDirectory.appendingPathComponent("backend")
        if FileManager.default.fileExists(atPath: currentBackend.path) {
            return currentBackend
        }

        return URL(fileURLWithPath: "/Users/a/Desktop/soloPJ/mwoham/backend")
    }
}
