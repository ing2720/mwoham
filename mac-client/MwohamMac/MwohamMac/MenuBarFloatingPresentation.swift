//
//  MenuBarFloatingPresentation.swift
//  MwohamMac
//

import Foundation

@MainActor
protocol AppStatusPresentationProviding: AnyObject {
    var connectionState: ConnectionState { get }
    var backendAddressText: String { get }
    var recordingState: RecordingState { get }
    var recordingElapsedTime: String { get }
    var activeWindowTrackingState: CollectorState { get }
    var ocrState: CollectorState { get }
    var devTrackingState: CollectorState { get }
    var shortDevTrackingStatus: String { get }
    var currentApp: String { get }
    var currentWindow: String { get }
    var isPrivateAppActive: Bool { get }
    var isLoading: Bool { get }
}

struct MenuBarFloatingPresentation: Equatable {
    struct QuickActions: Equatable {
        let openMainWindowTitle = "메인 창 열기"
        let floatingWidgetTitle: String
        let openDashboardTitle = "대시보드 열기"
        let refreshTitle = "새로고침"
        let quitTitle = "앱 종료"
        let canRefresh: Bool
    }

    let backendState: ConnectionState
    let backendDetail: String?
    let recordingState: RecordingState
    let recordingElapsedTimeText: String
    let activeWindowTrackingState: CollectorState
    let activeWindowTrackingTitle = "활성 창 추적"
    let ocrState: CollectorState
    let ocrTitle = "OCR 상태"
    let devTrackingState: CollectorState
    let devTrackingTitle = "Dev Tracking"
    let currentAppText: String
    let currentWindowText: String
    let collapsedDetailText: String
    let quickActions: QuickActions

    @MainActor
    init(
        provider: AppStatusPresentationProviding,
        isFloatingWidgetVisible: Bool
    ) {
        self.init(
            backendState: provider.connectionState,
            backendAddressText: provider.backendAddressText,
            recordingState: provider.recordingState,
            recordingElapsedTimeText: provider.recordingElapsedTime,
            activeWindowTrackingState: provider.activeWindowTrackingState,
            ocrState: provider.ocrState,
            devTrackingState: provider.devTrackingState,
            shortDevTrackingStatus: provider.shortDevTrackingStatus,
            currentApp: provider.currentApp,
            currentWindow: provider.currentWindow,
            isPrivateAppActive: provider.isPrivateAppActive,
            isLoading: provider.isLoading,
            isFloatingWidgetVisible: isFloatingWidgetVisible
        )
    }

    init(
        backendState: ConnectionState,
        backendAddressText: String,
        recordingState: RecordingState,
        recordingElapsedTimeText: String,
        activeWindowTrackingState: CollectorState,
        ocrState: CollectorState,
        devTrackingState: CollectorState,
        shortDevTrackingStatus: String,
        currentApp: String,
        currentWindow: String,
        isPrivateAppActive: Bool,
        isLoading: Bool,
        isFloatingWidgetVisible: Bool
    ) {
        self.backendState = backendState
        self.backendDetail = backendState.isError
            ? "로컬 서버 확인: \(backendAddressText)"
            : nil
        self.recordingState = recordingState
        self.recordingElapsedTimeText =
            Self.displayValue(recordingElapsedTimeText, fallback: "00:00:00")
        self.activeWindowTrackingState = activeWindowTrackingState
        self.ocrState = ocrState
        self.devTrackingState = devTrackingState
        self.currentAppText = Self.displayValue(
            currentApp,
            fallback: "현재 앱 없음"
        )
        self.currentWindowText = Self.displayValue(
            currentWindow,
            fallback: "현재 창 없음",
            maxLength: 90
        )
        self.quickActions = QuickActions(
            floatingWidgetTitle:
                isFloatingWidgetVisible ? "플로팅 위젯 닫기" : "플로팅 위젯 열기",
            canRefresh: !isLoading
        )

        if backendState.isError {
            collapsedDetailText = "연결 실패"
        } else if isPrivateAppActive {
            collapsedDetailText = "비공개"
        } else {
            collapsedDetailText =
                "\(self.recordingElapsedTimeText) · \(shortDevTrackingStatus)"
        }
    }

    private static func displayValue(
        _ value: String,
        fallback: String,
        maxLength: Int = 40
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-", trimmed != "없음" else {
            return fallback
        }
        guard trimmed.count > maxLength else {
            return trimmed
        }
        return String(trimmed.prefix(maxLength - 3)) + "..."
    }
}

#if !MWOHAM_PRESENTATION_HARNESS
extension BackendStatusViewModel: AppStatusPresentationProviding {}
#endif
