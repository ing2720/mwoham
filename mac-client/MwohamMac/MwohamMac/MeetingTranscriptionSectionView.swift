//
//  MeetingTranscriptionSectionView.swift
//  MwohamMac
//

import SwiftUI

struct MeetingTranscriptionSectionView: View {
    @ObservedObject var viewModel: BackendStatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.startMeetingTranscription()
                    }
                } label: {
                    Label("회의 전사 시작", systemImage: "mic.circle")
                }
                .disabled(!viewModel.canStartMeetingTranscription)

                Button {
                    Task {
                        await viewModel.stopMeetingTranscription()
                    }
                } label: {
                    Label("회의 전사 종료", systemImage: "stop.circle")
                }
                .disabled(!viewModel.canStopMeetingTranscription)
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("전사 상태")
                        .foregroundStyle(.secondary)
                    Text(viewModel.transcriptionStatus)
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("최근 전사")
                        .foregroundStyle(.secondary)
                    Text(latestTranscriptText)
                        .fontWeight(.medium)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var latestTranscriptText: String {
        viewModel.latestTranscriptText.isEmpty ? "아직 전사된 텍스트가 없습니다." : viewModel.latestTranscriptText
    }
}
