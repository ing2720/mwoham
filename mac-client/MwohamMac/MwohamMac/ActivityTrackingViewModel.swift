//
//  ActivityTrackingViewModel.swift
//  MwohamMac
//

import Combine
import Foundation

@MainActor
final class ActivityTrackingViewModel: ObservableObject {
    @Published private(set) var currentApp = "-"
    @Published private(set) var currentWindow = "-"
    @Published private(set) var activeWindowState =
        CollectorState.idle("활성 창 추적 대기 중")
    @Published private(set) var ocrState = CollectorState.idle("OCR 대기 중")
    @Published private(set) var devTrackingState =
        CollectorState.idle("Dev Tracking: 대기 중")
    @Published private(set) var isPrivateAppActive = false
    @Published var devTrackingRepoPath: String {
        didSet {
            UserDefaults.standard.set(devTrackingRepoPath, forKey: Self.repoPathKey)
        }
    }
    @Published private(set) var devTrackingManualStartRequested = false
    @Published private(set) var isDevTrackingRunning = false
    private var isDevTrackingAutomaticSessionActive = false

    private static let repoPathKey = "devTrackingRepoPath"
    private let activeWindowCollector: ActiveWindowCollector
    private let ocrCollector: OCRCollector
    private let devTrackingProcessController: DevTrackingProcessController
    private var isRecordingActive: () -> Bool = { false }
    private var isBackendConnected: () -> Bool = { false }

    init(localApiClient: LocalApiClient) {
        devTrackingRepoPath =
            UserDefaults.standard.string(forKey: Self.repoPathKey) ?? ""
        activeWindowCollector = ActiveWindowCollector(localApiClient: localApiClient)
        ocrCollector = OCRCollector(localApiClient: localApiClient)
        devTrackingProcessController = DevTrackingProcessController(
            repoPathProvider: {
                UserDefaults.standard.string(forKey: Self.repoPathKey) ?? ""
            }
        )
    }

    func configure(
        isRecordingActive: @escaping () -> Bool,
        isBackendConnected: @escaping () -> Bool
    ) {
        self.isRecordingActive = isRecordingActive
        self.isBackendConnected = isBackendConnected
    }

    var shortDevTrackingLabel: String {
        if devTrackingState.isError {
            return "오류"
        }
        return devTrackingState.isRunning ? "Dev 추적 중" : "대기"
    }

    func startActiveWindowTracking() {
        activeWindowCollector.start(
            isRecordingActive: { [weak self] in
                self?.isRecordingActive() == true
            },
            onStatusChange: { [weak self] status in
                self?.activeWindowState = CollectorState(statusText: status)
            },
            onSnapshot: { [weak self] snapshot in
                self?.isPrivateAppActive = false
                self?.currentApp = snapshot.appName
                self?.currentWindow = Self.displayValue(snapshot.windowTitle)
            },
            onPrivateAppChange: { [weak self] isActive in
                self?.isPrivateAppActive = isActive
                if isActive {
                    self?.currentApp = "비공개 앱"
                    self?.currentWindow = "비공개 앱 사용 중"
                }
            },
            onFrontmostAppChange: { [weak self] appName in
                guard let self else {
                    return
                }
                if self.isDevTrackingAutomaticSessionActive {
                    if self.devTrackingProcessController.isRunning {
                        self.applyDevTrackingStatus("Dev Tracking: 기록 세션 자동 감시 중")
                    }
                    return
                }
                guard self.devTrackingManualStartRequested else {
                    self.devTrackingState = CollectorState(
                        statusText: "Dev Tracking: 수동 시작 대기 중"
                    )
                    return
                }
                self.devTrackingProcessController.handleActiveApplication(appName) {
                    [weak self] status in
                    self?.applyDevTrackingStatus(status)
                }
            }
        )
    }

    func startOCRCollection() {
        ocrCollector.start(
            isRecordingActive: { [weak self] in
                self?.isRecordingActive() == true
            },
            isPrivateAppActive: { [weak self] in
                self?.isPrivateAppActive == true
            },
            currentApp: { [weak self] in
                self?.currentApp ?? "-"
            },
            currentWindow: { [weak self] in
                self?.currentWindow ?? "-"
            },
            onStatusChange: { [weak self] status in
                self?.ocrState = CollectorState(statusText: status)
            }
        )
    }

    func stopCollectors() {
        activeWindowCollector.stop()
        ocrCollector.stop()
        devTrackingManualStartRequested = false
        isDevTrackingAutomaticSessionActive = false
        devTrackingProcessController.stop { [weak self] status in
            self?.applyDevTrackingStatus(status)
        }
        activeWindowState = .idle("활성 창 추적 대기 중")
        ocrState = .idle("OCR 대기 중")
    }

    func startDevTracking() {
        devTrackingManualStartRequested = true
        if repoPathForDisplay().contains("/Desktop/") {
            devTrackingState = CollectorState(
                statusText: "Dev Tracking: Desktop repo 접근 권한이 필요할 수 있음"
            )
        }
        devTrackingProcessController.handleActiveApplication(currentApp) {
            [weak self] status in
            self?.applyDevTrackingStatus(status)
        }
    }

    func stopDevTracking() {
        devTrackingManualStartRequested = false
        devTrackingProcessController.stop { [weak self] status in
            self?.applyDevTrackingStatus(status)
        }
    }

    func handleRecordingTransition(_ transition: DevTrackingRecordingTransition) {
        switch DevTrackingAutomationPolicy.action(for: transition) {
        case .start:
            isDevTrackingAutomaticSessionActive = true
            devTrackingProcessController.start(
                backendConnected: isBackendConnected()
            ) { [weak self] status in
                self?.applyDevTrackingStatus(status)
            }
        case .stop:
            isDevTrackingAutomaticSessionActive = false
            devTrackingProcessController.stop { [weak self] status in
                self?.applyDevTrackingStatus(status)
            }
        case .none:
            break
        }
    }

    func applyStatus(_ status: StatusResponse) {
        guard !isPrivateAppActive else {
            currentApp = "비공개 앱"
            currentWindow = "비공개 앱 사용 중"
            return
        }
        currentApp = Self.displayValue(status.currentApp)
        currentWindow = Self.displayValue(status.currentWindow)
    }

    func resetDisplayedActivity() {
        currentApp = "-"
        currentWindow = "-"
    }

    private func repoPathForDisplay() -> String {
        let configuredPath = devTrackingRepoPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configuredPath.isEmpty
            ? DevTrackingProcessController.defaultRepoPathForDisplay()
            : configuredPath
    }

    private func applyDevTrackingStatus(_ status: String) {
        devTrackingState = CollectorState(statusText: status)
        isDevTrackingRunning = devTrackingProcessController.isRunning
    }

    private static func displayValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "없음"
        }
        return value
    }
}
