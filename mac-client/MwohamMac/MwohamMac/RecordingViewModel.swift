//
//  RecordingViewModel.swift
//  MwohamMac
//

import Combine
import Foundation

@MainActor
final class RecordingViewModel: ObservableObject {
    @Published private(set) var state: RecordingState = .unknown
    @Published private(set) var elapsedTime = "기록 중 아님"
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let localApiClient: LocalApiClient
    private var sessionStartedAt: Date?
    private var statusElapsedSeconds: Int?
    private var statusReceivedAt: Date?
    private var isConnected: () -> Bool = { false }
    private var onSnapshotReceived: (BackendSnapshot) -> Void = { _ in }
    private var onRefreshAfterFailedAction: () async -> Void = {}
    private var onSuccessfulAction: (DevTrackingRecordingTransition) -> Void = { _ in }

    init(localApiClient: LocalApiClient) {
        self.localApiClient = localApiClient
    }

    func configure(
        isConnected: @escaping () -> Bool,
        onSnapshotReceived: @escaping (BackendSnapshot) -> Void,
        onRefreshAfterFailedAction: @escaping () async -> Void,
        onSuccessfulAction: @escaping (DevTrackingRecordingTransition) -> Void
    ) {
        self.isConnected = isConnected
        self.onSnapshotReceived = onSnapshotReceived
        self.onRefreshAfterFailedAction = onRefreshAfterFailedAction
        self.onSuccessfulAction = onSuccessfulAction
    }

    var canStart: Bool {
        canUseControls && state == .stopped
    }

    var canPause: Bool {
        canUseControls && state == .active
    }

    var canResume: Bool {
        canUseControls && state == .paused
    }

    var canStop: Bool {
        canUseControls && state.isRunning
    }

    func start() async {
        await run(.start)
    }

    func pause() async {
        await run(.pause)
    }

    func resume() async {
        await run(.resume)
    }

    func stop() async {
        await run(.stop)
    }

    func applyStatus(_ status: StatusResponse, receivedAt: Date = Date()) {
        state = RecordingState(apiValue: status.status)
        sessionStartedAt = parseDate(status.sessionStartedAt)
        statusElapsedSeconds = status.elapsedSeconds
        statusReceivedAt = receivedAt
        elapsedTime = makeElapsedTimeText(at: receivedAt)
    }

    func reset() {
        state = .unknown
        elapsedTime = "기록 중 아님"
        sessionStartedAt = nil
        statusElapsedSeconds = nil
        statusReceivedAt = nil
    }

    func updateElapsedTime() {
        elapsedTime = makeElapsedTimeText(at: Date())
    }

    private var canUseControls: Bool {
        isConnected() && !isLoading
    }

    private func run(_ action: RecordingAction) async {
        isLoading = true
        errorMessage = nil

        do {
            switch action {
            case .start:
                try await localApiClient.startRecording()
            case .pause:
                try await localApiClient.pauseRecording()
            case .resume:
                try await localApiClient.resumeRecording()
            case .stop:
                try await localApiClient.stopRecording()
            }

            onSuccessfulAction(action.devTrackingTransition)
            let snapshot = try await localApiClient.fetchSnapshot()
            onSnapshotReceived(snapshot)
        } catch {
            errorMessage = "\(action.errorTitle) 요청 실패: \(error.localizedDescription)"
            await onRefreshAfterFailedAction()
        }

        isLoading = false
    }

    private func makeElapsedTimeText(at now: Date) -> String {
        switch state {
        case .active:
            if let sessionStartedAt {
                return formatElapsedSeconds(Int(max(0, now.timeIntervalSince(sessionStartedAt))))
            }
            if let statusElapsedSeconds, let statusReceivedAt {
                return formatElapsedSeconds(
                    statusElapsedSeconds + Int(max(0, now.timeIntervalSince(statusReceivedAt)))
                )
            }
            return "-"
        case .paused:
            if let statusElapsedSeconds {
                return formatElapsedSeconds(statusElapsedSeconds)
            }
            if let sessionStartedAt, let statusReceivedAt {
                return formatElapsedSeconds(
                    Int(max(0, statusReceivedAt.timeIntervalSince(sessionStartedAt)))
                )
            }
            return "-"
        case .stopped, .unknown:
            return "기록 중 아님"
        }
    }

    private func formatElapsedSeconds(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 {
            return "\(totalSeconds)초"
        }
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 {
            return "\(totalMinutes)분"
        }
        return String(format: "%d시간 %02d분", totalMinutes / 60, totalMinutes % 60)
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private enum RecordingAction {
    case start
    case pause
    case resume
    case stop

    var errorTitle: String {
        switch self {
        case .start:
            return "기록 시작"
        case .pause:
            return "일시정지"
        case .resume:
            return "재개"
        case .stop:
            return "기록 종료"
        }
    }

    var devTrackingTransition: DevTrackingRecordingTransition {
        switch self {
        case .start:
            return .started
        case .pause:
            return .paused
        case .resume:
            return .resumed
        case .stop:
            return .stopped
        }
    }
}
