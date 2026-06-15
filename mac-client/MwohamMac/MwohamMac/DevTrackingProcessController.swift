//
//  DevTrackingProcessController.swift
//  MwohamMac
//

import AppKit
import Foundation

@MainActor
final class DevTrackingProcessController {
    private let backendPath: URL
    private let repoPathProvider: () -> String
    private let intervalSeconds: Int
    private let debounceSeconds: TimeInterval
    private var process: Process?
    private var lastStartAttemptAt: Date?
    private var terminationObserver: NSObjectProtocol?
    private var lastErrorOutput = ""
    private var stdoutBuffer = ""
    private var stderrBuffer = ""

    init(
        backendPath: URL = DevTrackingProcessController.defaultBackendPath(),
        repoPathProvider: @escaping () -> String = { "" },
        intervalSeconds: Int = 60,
        debounceSeconds: TimeInterval = 10
    ) {
        self.backendPath = backendPath
        self.repoPathProvider = repoPathProvider
        self.intervalSeconds = intervalSeconds
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

    func start(
        backendConnected: Bool,
        onStatusChange: @escaping (String) -> Void
    ) {
        let repoURL = configuredRepoURL()
        switch DevTrackingAutomationPolicy.startDecision(
            backendConnected: backendConnected,
            isRunning: isRunning,
            repoURL: repoURL
        ) {
        case let .start(validatedRepoURL):
            launch(repoURL: validatedRepoURL, onStatusChange: onStatusChange)
        case .alreadyRunning:
            onStatusChange("Dev Tracking: 이미 감시 중")
        case let .blocked(message):
            onStatusChange(message)
        }
    }

    func stop(onStatusChange: ((String) -> Void)? = nil) {
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

    private func launch(
        repoURL: URL,
        onStatusChange: @escaping (String) -> Void
    ) {
        if let lastStartAttemptAt,
           Date().timeIntervalSince(lastStartAttemptAt) < debounceSeconds {
            onStatusChange("Dev Tracking: 시작 대기 중")
            return
        }

        lastStartAttemptAt = Date()

        guard FileManager.default.fileExists(atPath: backendPath.path) else {
            onStatusChange("Dev Tracking 오류: backend 경로를 찾을 수 없습니다.")
            return
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        lastErrorOutput = ""
        stdoutBuffer = ""
        stderrBuffer = ""
        process.currentDirectoryURL = backendPath
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "uv",
            "run",
            "python",
            "scripts/watch_dev_context.py",
            "--repo-path",
            repoURL.path,
            "--interval",
            "\(intervalSeconds)",
            "--session-current",
        ]
        process.environment = processEnvironment()
        process.standardOutput = standardOutput
        process.standardError = standardError
        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleProcessOutput(text, isError: false, onStatusChange: onStatusChange)
            }
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleProcessOutput(text, isError: true, onStatusChange: onStatusChange)
            }
        }
        process.terminationHandler = { [weak self, weak process] terminatedProcess in
            Task { @MainActor [weak self, weak process] in
                guard let self, let process, process === terminatedProcess else {
                    return
                }
                self.clearPipeHandlers(
                    standardOutput: standardOutput,
                    standardError: standardError
                )
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
            onStatusChange("Dev Tracking: 감시 중")
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
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    private func configuredRepoURL() -> URL {
        let configuredPath = repoPathProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        if configuredPath.isEmpty {
            return backendPath.deletingLastPathComponent()
        }

        if configuredPath.hasPrefix("/") {
            return URL(fileURLWithPath: configuredPath)
        }

        return backendPath.appendingPathComponent(configuredPath)
    }

    private func handleProcessOutput(
        _ text: String,
        isError: Bool,
        onStatusChange: @escaping (String) -> Void
    ) {
        if isError {
            stderrBuffer += text
            let lines = completeLines(from: &stderrBuffer)
            for line in lines {
                let message = truncate(line.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !message.isEmpty else {
                    continue
                }
                lastErrorOutput = message
                onStatusChange("Dev Tracking 오류: \(message)")
            }
            return
        }

        stdoutBuffer += text
        let lines = completeLines(from: &stdoutBuffer)
        for line in lines {
            let message = statusMessage(for: line.trimmingCharacters(in: .whitespacesAndNewlines))
            if !message.isEmpty {
                onStatusChange(message)
            }
        }
    }

    private func completeLines(from buffer: inout String) -> [String] {
        let parts = buffer.split(separator: "\n", omittingEmptySubsequences: false)
        guard buffer.contains("\n") else {
            return []
        }

        let hasTrailingNewline = buffer.hasSuffix("\n")
        buffer = hasTrailingNewline ? "" : String(parts.last ?? "")
        let completedParts = hasTrailingNewline ? parts : parts.dropLast()
        return completedParts.map(String.init)
    }

    private func statusMessage(for outputLine: String) -> String {
        guard !outputLine.isEmpty else {
            return ""
        }

        if outputLine.hasPrefix("Dev tracking 감시 시작") {
            return "Dev Tracking: 감시 시작"
        }
        if outputLine == "변경 없음" {
            return "Dev Tracking: 변경 없음"
        }
        if outputLine == "변경 감지, 안정화 대기 중" {
            return "Dev Tracking: 변경 감지, 안정화 대기 중"
        }
        if outputLine.hasPrefix("변경 감지, DevEvent 저장됨: ") {
            return "Dev Tracking: \(truncate(outputLine.replacingOccurrences(of: "변경 감지, DevEvent 저장됨: ", with: "")))"
        }
        if let summary = extractSavedEventSummary(from: outputLine) {
            return "Dev Tracking: \(truncate(summary))"
        }
        if outputLine == "Dev tracking 1회 확인 완료" {
            return "Dev Tracking: 1회 확인 완료"
        }
        if outputLine == "Dev tracking 감시 종료" {
            return "Dev Tracking: 종료됨"
        }
        if outputLine == "Git 저장소가 아닙니다" {
            return "Dev Tracking 오류: Git 저장소가 아닙니다"
        }

        return "Dev Tracking: \(truncate(outputLine))"
    }

    private func extractSavedEventSummary(from outputLine: String) -> String? {
        guard outputLine.hasPrefix("DevEvent 저장됨:") else {
            return nil
        }
        guard let summaryRange = outputLine.range(of: "summary=") else {
            return outputLine
        }
        return String(outputLine[summaryRange.upperBound...])
    }

    private func truncate(_ text: String, limit: Int = 180) -> String {
        if text.count <= limit {
            return text
        }
        return "\(text.prefix(limit - 1))..."
    }

    private func clearPipeHandlers(standardOutput: Pipe?, standardError: Pipe?) {
        standardOutput?.fileHandleForReading.readabilityHandler = nil
        standardError?.fileHandleForReading.readabilityHandler = nil
    }

    nonisolated static func defaultRepoPathForDisplay(filePath: String = #filePath) -> String {
        defaultBackendPath(filePath: filePath).deletingLastPathComponent().path
    }

    nonisolated private static func defaultBackendPath(filePath: String = #filePath) -> URL {
        let sourceFile = URL(fileURLWithPath: filePath)
        return sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backend")
    }
}
