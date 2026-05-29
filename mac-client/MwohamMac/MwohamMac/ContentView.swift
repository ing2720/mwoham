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
            isConnected = snapshot.health.status == "ok"
            recordingStatus = snapshot.status.status
            meetingMode = snapshot.status.meetingMode ? "켜짐" : "꺼짐"
            currentApp = displayValue(snapshot.status.currentApp)
            currentWindow = displayValue(snapshot.status.currentWindow)
        } catch {
            isConnected = false
            recordingStatus = "-"
            meetingMode = "-"
            currentApp = "-"
            currentWindow = "-"
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func displayValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "없음"
        }

        return value
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
