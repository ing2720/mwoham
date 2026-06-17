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
    var isDevTrackingRunning: Bool { get }
    var shortDevTrackingStatus: String { get }
    var currentApp: String { get }
    var currentWindow: String { get }
    var isPrivateAppActive: Bool { get }
    var isLoading: Bool { get }
    var meetingModeState: MeetingTranscriptionState { get }
    var canStartMeetingMode: Bool { get }
    var canStopMeetingMode: Bool { get }
}

struct MenuBarFloatingPresentation: Equatable {
    enum MenuBarIconState: Equatable {
        case idle
        case recording
        case paused
        case meeting
        case error

        var systemImage: String {
            switch self {
            case .idle:
                return "circle"
            case .recording:
                return "record.circle.fill"
            case .paused:
                return "pause.circle.fill"
            case .meeting:
                return "waveform.circle.fill"
            case .error:
                return "exclamationmark.circle.fill"
            }
        }
    }

    enum DevTrackingBadgeState: Equatable {
        case running
        case stopping
        case stopped
        case error

        var label: String {
            switch self {
            case .running:
                return "Dev Tracking:기록중"
            case .stopping:
                return "Dev Tracking:종료중"
            case .stopped:
                return "Dev Tracking:기록중지"
            case .error:
                return "Dev Tracking:error"
            }
        }
    }

    struct ControlActions: Equatable {
        let recordingStartLabel = "기록 시작"
        let recordingPauseResumeLabel: String
        let recordingStopLabel = "기록 종료"
        let devTrackingToggleLabel: String
        let meetingModeToggleLabel: String
        let restartLabel = "앱 다시시작"
        let isRecordingStartDisabled: Bool
        let isRecordingPauseResumeDisabled: Bool
        let isRecordingStopDisabled: Bool
        let isDevTrackingToggleDisabled: Bool
        let isMeetingModeToggleDisabled: Bool
    }

    struct QuickActions: Equatable {
        let openMainWindowTitle = "메인 창 열기"
        let floatingWidgetTitle: String
        let openDashboardTitle = "대시보드 열기"
        let refreshTitle = "새로고침"
        let quitTitle = "앱 종료"
        let canRefresh: Bool
    }

    let menuBarIconState: MenuBarIconState
    let menuBarIconName: String
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
    let devTrackingBadgeState: DevTrackingBadgeState
    let devTrackingBadgeText: String
    let devTrackingDisplayText: String
    let currentAppText: String
    let currentWindowText: String
    let collapsedDetailText: String
    let widgetSettingsLabel = "위젯 설정"
    let widgetCompactToggleLabel = "간편보기"
    let controlActions: ControlActions
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
            isDevTrackingRunning: provider.isDevTrackingRunning,
            shortDevTrackingStatus: provider.shortDevTrackingStatus,
            currentApp: provider.currentApp,
            currentWindow: provider.currentWindow,
            isPrivateAppActive: provider.isPrivateAppActive,
            isLoading: provider.isLoading,
            meetingModeState: provider.meetingModeState,
            canStartMeetingMode: provider.canStartMeetingMode,
            canStopMeetingMode: provider.canStopMeetingMode,
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
        isDevTrackingRunning: Bool,
        shortDevTrackingStatus: String,
        currentApp: String,
        currentWindow: String,
        isPrivateAppActive: Bool,
        isLoading: Bool,
        meetingModeState: MeetingTranscriptionState,
        canStartMeetingMode: Bool,
        canStopMeetingMode: Bool,
        isFloatingWidgetVisible: Bool
    ) {
        self.menuBarIconState = Self.iconState(
            backendState: backendState,
            recordingState: recordingState,
            meetingModeState: meetingModeState
        )
        self.menuBarIconName = menuBarIconState.systemImage
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
        self.devTrackingBadgeState = Self.devTrackingBadgeState(
            state: devTrackingState,
            isRunning: isDevTrackingRunning
        )
        self.devTrackingBadgeText = devTrackingBadgeState.label
        self.devTrackingDisplayText = Self.devTrackingDisplayText(
            state: devTrackingState,
            badgeState: devTrackingBadgeState
        )
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
        self.controlActions = ControlActions(
            recordingPauseResumeLabel:
                recordingState == .paused ? "기록 재개" : "기록 일시정지",
            devTrackingToggleLabel:
                isDevTrackingRunning ? "Dev Tracking 종료" : "Dev Tracking 시작",
            meetingModeToggleLabel:
                meetingModeState.isRunning ? "회의모드 종료" : "회의모드 시작",
            isRecordingStartDisabled: recordingState != .stopped,
            isRecordingPauseResumeDisabled:
                !(recordingState == .active || recordingState == .paused),
            isRecordingStopDisabled: !recordingState.isRunning,
            isDevTrackingToggleDisabled: false,
            isMeetingModeToggleDisabled:
                meetingModeState.isRunning
                    ? !canStopMeetingMode
                    : !canStartMeetingMode
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

    private static func iconState(
        backendState: ConnectionState,
        recordingState: RecordingState,
        meetingModeState: MeetingTranscriptionState
    ) -> MenuBarIconState {
        if backendState.isError {
            return .error
        }
        if meetingModeState.isRunning {
            return .meeting
        }
        switch recordingState {
        case .active:
            return .recording
        case .paused:
            return .paused
        case .stopped, .unknown:
            return .idle
        }
    }

    private static func devTrackingBadgeState(
        state: CollectorState,
        isRunning: Bool
    ) -> DevTrackingBadgeState {
        if state.isError {
            return .error
        }
        if state.label.contains("종료 중")
            || state.label.contains("종료중") {
            return .stopping
        }
        return isRunning || state.isRunning ? .running : .stopped
    }

    private static func devTrackingDisplayText(
        state: CollectorState,
        badgeState: DevTrackingBadgeState
    ) -> String {
        switch badgeState {
        case .running:
            return "Dev Tracking:기록중"
        case .stopping:
            return "Dev Tracking:종료중"
        case .stopped:
            return "Dev Tracking:기록중지"
        case .error:
            return "Dev Tracking:error\(Self.errorCode(from: state.label))"
        }
    }

    private static func errorCode(from label: String) -> String {
        guard let range = label.range(
            of: #"(?<=코드 )\d+"#,
            options: .regularExpression
        ) else {
            return ""
        }
        return String(label[range])
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
extension BackendStatusViewModel: AppStatusPresentationProviding {
    var isDevTrackingRunning: Bool {
        activityTracking.isDevTrackingRunning
    }

    var meetingModeState: MeetingTranscriptionState {
        meetingTranscription.state
    }

    var canStartMeetingMode: Bool {
        meetingTranscription.canStart
    }

    var canStopMeetingMode: Bool {
        meetingTranscription.canStop
    }
}
#endif
