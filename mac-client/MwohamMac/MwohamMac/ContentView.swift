//
//  ContentView.swift
//  MwohamMac
//
//  Created by a on 5/29/26.
//

import Combine
import SwiftUI

@MainActor
final class BackendStatusViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var isConnected = false
    @Published var recordingStatus = "-"
    @Published var recordingElapsedTime = "기록 중 아님"
    @Published var meetingMode = "-"
    @Published var currentApp = "-"
    @Published var currentWindow = "-"
    @Published var errorMessage: String?
    @Published var memoContent = ""
    @Published var memoStatusMessage = ""
    @Published var isSavingMemo = false

    private let localApiClient: LocalApiClient
    private var rawRecordingStatus = "unknown"
    private var sessionStartedAt: Date?
    private var statusElapsedSeconds: Int?
    private var statusReceivedAt: Date?

    init() {
        self.localApiClient = LocalApiClient()
    }

    init(localApiClient: LocalApiClient) {
        self.localApiClient = localApiClient
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil

        do {
            let snapshot = try await localApiClient.fetchSnapshot()
            applySnapshot(snapshot)
        } catch {
            isConnected = false
            rawRecordingStatus = "unknown"
            recordingStatus = "-"
            recordingElapsedTime = "기록 중 아님"
            meetingMode = "-"
            currentApp = "-"
            currentWindow = "-"
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func startRecording() async {
        await runRecordingAction(.start)
    }

    func pauseRecording() async {
        await runRecordingAction(.pause)
    }

    func resumeRecording() async {
        await runRecordingAction(.resume)
    }

    func stopRecording() async {
        await runRecordingAction(.stop)
    }

    func saveMemo() async {
        guard !isSavingMemo else {
            return
        }

        let trimmedContent = memoContent.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedContent.isEmpty else {
            memoStatusMessage = "메모 내용을 입력해 주세요."
            return
        }

        isSavingMemo = true
        memoStatusMessage = "메모 저장 중..."

        do {
            try await localApiClient.createMemo(content: trimmedContent)
            memoContent = ""
            memoStatusMessage = "메모가 저장되었습니다."

            let snapshot = try await localApiClient.fetchSnapshot()
            applySnapshot(snapshot)
        } catch {
            memoStatusMessage = "메모 저장에 실패했습니다: \(error.localizedDescription)"
            await refreshAfterFailedAction()
        }

        isSavingMemo = false
    }

    var canStartRecording: Bool {
        canUseControls && rawRecordingStatus == "stopped"
    }

    var canPauseRecording: Bool {
        canUseControls && rawRecordingStatus == "active"
    }

    var canResumeRecording: Bool {
        canUseControls && rawRecordingStatus == "paused"
    }

    var canStopRecording: Bool {
        canUseControls && (rawRecordingStatus == "active" || rawRecordingStatus == "paused")
    }

    var canSaveMemo: Bool {
        isConnected && !isSavingMemo
    }

    func updateElapsedTime() {
        recordingElapsedTime = makeElapsedTimeText(at: Date())
    }

    private func displayValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "없음"
        }

        return value
    }

    private var canUseControls: Bool {
        isConnected && !isLoading
    }

    private func runRecordingAction(_ action: RecordingAction) async {
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

            let snapshot = try await localApiClient.fetchSnapshot()
            applySnapshot(snapshot)
        } catch {
            errorMessage = "\(action.errorTitle) 요청 실패: \(error.localizedDescription)"
            await refreshAfterFailedAction()
        }

        isLoading = false
    }

    private func refreshAfterFailedAction() async {
        do {
            let snapshot = try await localApiClient.fetchSnapshot()
            applySnapshot(snapshot)
        } catch {
            isConnected = false
        }
    }

    private func applySnapshot(_ snapshot: BackendSnapshot) {
        let receivedAt = Date()
        isConnected = snapshot.health.status == "ok"
        rawRecordingStatus = snapshot.status.status
        recordingStatus = snapshot.status.status
        sessionStartedAt = parseDate(snapshot.status.sessionStartedAt)
        statusElapsedSeconds = snapshot.status.elapsedSeconds
        statusReceivedAt = receivedAt
        recordingElapsedTime = makeElapsedTimeText(at: receivedAt)
        meetingMode = snapshot.status.meetingMode ? "켜짐" : "꺼짐"
        currentApp = displayValue(snapshot.status.currentApp)
        currentWindow = displayValue(snapshot.status.currentWindow)
    }

    private func makeElapsedTimeText(at now: Date) -> String {
        switch rawRecordingStatus {
        case "active":
            if let sessionStartedAt {
                return formatElapsedSeconds(Int(max(0, now.timeIntervalSince(sessionStartedAt))))
            }

            if let statusElapsedSeconds, let statusReceivedAt {
                let elapsedSinceStatus = Int(max(0, now.timeIntervalSince(statusReceivedAt)))
                return formatElapsedSeconds(statusElapsedSeconds + elapsedSinceStatus)
            }

            return "-"
        case "paused":
            if let statusElapsedSeconds {
                return formatElapsedSeconds(statusElapsedSeconds)
            }

            if let sessionStartedAt, let statusReceivedAt {
                return formatElapsedSeconds(Int(max(0, statusReceivedAt.timeIntervalSince(sessionStartedAt))))
            }

            return "-"
        default:
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

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return String(format: "%d시간 %02d분", hours, minutes)
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
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
}

struct ContentView: View {
    @ObservedObject var viewModel: BackendStatusViewModel

    init(viewModel: BackendStatusViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                ConnectionMessageView(isConnected: viewModel.isConnected)

                Spacer()

                Button {
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }

            Divider()

            RecordingControlsView(viewModel: viewModel)

            StatusSectionView(viewModel: viewModel)

            Divider()

            QuickMemoSectionView(viewModel: viewModel)

            if viewModel.isLoading {
                ProgressView("상태를 확인하는 중")
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 460, minHeight: 390, alignment: .topLeading)
        .padding(24)
        .task {
            await viewModel.refresh()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            viewModel.updateElapsedTime()
        }
    }
}
