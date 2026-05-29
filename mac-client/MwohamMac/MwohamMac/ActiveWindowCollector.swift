//
//  ActiveWindowCollector.swift
//  MwohamMac
//

import AppKit
import ApplicationServices
import Foundation

struct ActiveWindowSnapshot: Equatable {
    let appName: String
    let windowTitle: String?

    func hasSameTarget(as other: ActiveWindowSnapshot) -> Bool {
        appName == other.appName && normalizedWindowTitle == other.normalizedWindowTitle
    }

    private var normalizedWindowTitle: String {
        windowTitle ?? ""
    }
}

@MainActor
final class ActiveWindowCollector {
    private let localApiClient: LocalApiClient
    private let pollingInterval: TimeInterval
    private var pollingTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var currentSegment: CurrentActivitySegment?
    private var lastVisibleSnapshot: ActiveWindowSnapshot?
    private var privateApps: [PrivateAppResponse] = []
    private var lastPrivateAppsRefreshAt: Date?
    private let privateAppsRefreshInterval: TimeInterval = 60

    init(localApiClient: LocalApiClient, pollingInterval: TimeInterval = 2) {
        self.localApiClient = localApiClient
        self.pollingInterval = pollingInterval
    }

    func start(
        isRecordingActive: @escaping @MainActor () -> Bool,
        onStatusChange: @escaping @MainActor (String) -> Void,
        onSnapshot: @escaping @MainActor (ActiveWindowSnapshot) -> Void,
        onPrivateAppChange: @escaping @MainActor (Bool) -> Void
    ) {
        guard pollingTask == nil else {
            return
        }

        onStatusChange("기록 중일 때 활성 창 추적")
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.collectIfNeeded(
                    isRecordingActive: isRecordingActive,
                    onStatusChange: onStatusChange,
                    onSnapshot: onSnapshot,
                    onPrivateAppChange: onPrivateAppChange
                )
            }
        }

        pollingTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                await collectIfNeeded(
                    isRecordingActive: isRecordingActive,
                    onStatusChange: onStatusChange,
                    onSnapshot: onSnapshot,
                    onPrivateAppChange: onPrivateAppChange
                )

                do {
                    try await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        currentSegment = nil
        lastVisibleSnapshot = nil
        privateApps = []
        lastPrivateAppsRefreshAt = nil
    }

    private func collectIfNeeded(
        isRecordingActive: @escaping @MainActor () -> Bool,
        onStatusChange: @escaping @MainActor (String) -> Void,
        onSnapshot: @escaping @MainActor (ActiveWindowSnapshot) -> Void,
        onPrivateAppChange: @escaping @MainActor (Bool) -> Void
    ) async {
        guard isRecordingActive() else {
            onStatusChange("기록 중일 때 활성 창 추적")
            onPrivateAppChange(false)
            currentSegment = nil
            return
        }

        await refreshPrivateAppsIfNeeded()

        guard let snapshot = collectActiveWindowSnapshot() else {
            onStatusChange("활성 창 정보를 확인할 수 없습니다.")
            return
        }

        if isOwnApplication(snapshot) {
            onStatusChange("활성 창 추적 중")
            currentSegment = nil
            return
        }

        if isPrivateApp(snapshot.appName) {
            onPrivateAppChange(true)
            onStatusChange("비공개 앱 사용 중")
            currentSegment = nil
            return
        }

        onPrivateAppChange(false)
        onSnapshot(snapshot)
        lastVisibleSnapshot = snapshot
        onStatusChange("활성 창 추적 중")

        do {
            try await saveSegment(for: snapshot, seenAt: Date())
            onStatusChange("활성 창 추적 중")
        } catch {
            onStatusChange("활성 창 구간 저장 실패: \(error.localizedDescription)")
        }
    }

    private func saveSegment(for snapshot: ActiveWindowSnapshot, seenAt: Date) async throws {
        if let currentSegment, snapshot.hasSameTarget(as: currentSegment.snapshot) {
            let response = try await localApiClient.updateActivitySegment(
                id: currentSegment.id,
                lastSeenAt: seenAt
            )
            guard response.saved != false, let segmentID = response.id else {
                self.currentSegment = nil
                return
            }
            self.currentSegment = CurrentActivitySegment(
                id: segmentID,
                snapshot: snapshot,
                startedAt: currentSegment.startedAt
            )
            return
        }

        let response = try await localApiClient.createActivitySegment(
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            source: "mac_active_window",
            startedAt: seenAt,
            lastSeenAt: seenAt
        )
        guard response.saved != false, let segmentID = response.id else {
            currentSegment = nil
            return
        }
        currentSegment = CurrentActivitySegment(
            id: segmentID,
            snapshot: snapshot,
            startedAt: seenAt
        )
    }

    private func refreshPrivateAppsIfNeeded() async {
        let now = Date()
        if let lastPrivateAppsRefreshAt,
           now.timeIntervalSince(lastPrivateAppsRefreshAt) < privateAppsRefreshInterval {
            return
        }

        do {
            privateApps = try await localApiClient.fetchPrivateApps().filter(\.isEnabled)
            lastPrivateAppsRefreshAt = now
        } catch {
            lastPrivateAppsRefreshAt = now
        }
    }

    private func collectActiveWindowSnapshot() -> ActiveWindowSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appName = trimmed(application.localizedName) ?? trimmed(application.bundleIdentifier) ?? "알 수 없는 앱"
        let windowTitle = accessibilityWindowTitle(for: application.processIdentifier)
            ?? visibleWindowTitle(for: application.processIdentifier)

        return ActiveWindowSnapshot(appName: appName, windowTitle: windowTitle)
    }

    private func isOwnApplication(_ snapshot: ActiveWindowSnapshot) -> Bool {
        let ownName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        let ownDisplayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let candidates = [ownName, ownDisplayName, "MwohamMac", "Mwoham"].compactMap(trimmed)
        return candidates.contains(snapshot.appName)
    }

    private func isPrivateApp(_ appName: String) -> Bool {
        privateApps.contains { privateApp in
            matches(appName: appName, pattern: privateApp.appName, matchType: privateApp.matchType)
        }
    }

    private func matches(appName: String, pattern: String, matchType: String) -> Bool {
        switch matchType {
        case "exact":
            return appName == pattern
        case "contains":
            return appName.localizedCaseInsensitiveContains(pattern)
        case "regex":
            do {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(appName.startIndex..<appName.endIndex, in: appName)
                return regex.firstMatch(in: appName, range: range) != nil
            } catch {
                return false
            }
        default:
            return false
        }
    }

    private func accessibilityWindowTitle(for processID: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(processID)
        var focusedWindow: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        ) == .success, let focusedWindow else {
            return nil
        }

        let windowElement = focusedWindow as! AXUIElement
        var titleValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            windowElement,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success, let title = titleValue as? String else {
            return nil
        }

        return trimmed(title)
    }

    private func visibleWindowTitle(for processID: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard
                let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
                ownerPID == Int(processID),
                let layer = window[kCGWindowLayer as String] as? Int,
                layer == 0,
                let title = window[kCGWindowName as String] as? String,
                let trimmedTitle = trimmed(title)
            else {
                continue
            }

            return trimmedTitle
        }

        return nil
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

private struct CurrentActivitySegment {
    let id: Int
    let snapshot: ActiveWindowSnapshot
    let startedAt: Date
}
