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
    @Published var meetingMode = "-"
    @Published var currentApp = "-"
    @Published var currentWindow = "-"
    @Published var errorMessage: String?

    private let localApiClient: LocalApiClient
    private var rawRecordingStatus = "unknown"

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
        isConnected = snapshot.health.status == "ok"
        rawRecordingStatus = snapshot.status.status
        recordingStatus = snapshot.status.status
        meetingMode = snapshot.status.meetingMode ? "켜짐" : "꺼짐"
        currentApp = displayValue(snapshot.status.currentApp)
        currentWindow = displayValue(snapshot.status.currentWindow)
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
    @StateObject private var viewModel = BackendStatusViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("로컬 백엔드 상태")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Label(
                        viewModel.isConnected ? "백엔드 연결됨" : "백엔드 연결 실패",
                        systemImage: viewModel.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(viewModel.isConnected ? .green : .red)
                }

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

            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.startRecording()
                    }
                } label: {
                    Label("기록 시작", systemImage: "record.circle")
                }
                .disabled(!viewModel.canStartRecording)

                Button {
                    Task {
                        await viewModel.pauseRecording()
                    }
                } label: {
                    Label("일시정지", systemImage: "pause.circle")
                }
                .disabled(!viewModel.canPauseRecording)

                Button {
                    Task {
                        await viewModel.resumeRecording()
                    }
                } label: {
                    Label("재개", systemImage: "play.circle")
                }
                .disabled(!viewModel.canResumeRecording)

                Button {
                    Task {
                        await viewModel.stopRecording()
                    }
                } label: {
                    Label("기록 종료", systemImage: "stop.circle")
                }
                .disabled(!viewModel.canStopRecording)
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                StatusRow(title: "현재 기록 상태", value: viewModel.recordingStatus)
                StatusRow(title: "meeting_mode", value: viewModel.meetingMode)
                StatusRow(title: "current_app", value: viewModel.currentApp)
                StatusRow(title: "current_window", value: viewModel.currentWindow)
            }

            if viewModel.isLoading {
                ProgressView("상태를 확인하는 중")
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 420, minHeight: 260, alignment: .topLeading)
        .padding(24)
        .task {
            await viewModel.refresh()
        }
    }
}

private struct StatusRow: View {
    let title: String
    let value: String

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }
}
