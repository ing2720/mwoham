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

    init(localApiClient: LocalApiClient, pollingInterval: TimeInterval = 2) {
        self.localApiClient = localApiClient
        self.pollingInterval = pollingInterval
    }

    func start(
        isRecordingActive: @escaping @MainActor () -> Bool,
        onStatusChange: @escaping @MainActor (String) -> Void,
        onSnapshot: @escaping @MainActor (ActiveWindowSnapshot) -> Void
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
                    onSnapshot: onSnapshot
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
                    onSnapshot: onSnapshot
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
    }

    private func collectIfNeeded(
        isRecordingActive: @escaping @MainActor () -> Bool,
        onStatusChange: @escaping @MainActor (String) -> Void,
        onSnapshot: @escaping @MainActor (ActiveWindowSnapshot) -> Void
    ) async {
        guard isRecordingActive() else {
            onStatusChange("기록 중일 때 활성 창 추적")
            currentSegment = nil
            return
        }

        guard let snapshot = collectActiveWindowSnapshot() else {
            onStatusChange("활성 창 정보를 확인할 수 없습니다.")
            return
        }

        if isOwnApplication(snapshot) {
            onStatusChange("활성 창 추적 중")
            currentSegment = nil
            return
        }

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
            self.currentSegment = CurrentActivitySegment(
                id: response.id,
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
        currentSegment = CurrentActivitySegment(
            id: response.id,
            snapshot: snapshot,
            startedAt: seenAt
        )
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
