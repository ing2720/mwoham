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

            if viewModel.shouldShowSpeechPermissionHelp {
                VStack(alignment: .leading, spacing: 8) {
                    Text("음성 인식과 마이크 권한을 허용한 뒤 다시 시도해 주세요.")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack(spacing: 10) {
                        Button {
                            viewModel.openSpeechRecognitionSettings()
                        } label: {
                            Label("음성 인식 설정 열기", systemImage: "waveform")
                        }

                        Button {
                            viewModel.openMicrophoneSettings()
                        } label: {
                            Label("마이크 설정 열기", systemImage: "mic")
                        }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var latestTranscriptText: String {
        viewModel.latestTranscriptText.isEmpty ? "아직 전사된 텍스트가 없습니다." : viewModel.latestTranscriptText
    }
}
