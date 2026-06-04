//
//  MeetingTranscriptionSectionView.swift
//  MwohamMac
//

import SwiftUI

struct MeetingTranscriptionSectionView: View {
    @ObservedObject var viewModel: MeetingTranscriptionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("전사 입력", selection: $viewModel.selectedAudioSource) {
                ForEach(MeetingAudioSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.canChangeAudioSource)

            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.start()
                    }
                } label: {
                    Label("회의 전사 시작", systemImage: "mic.circle")
                }
                .disabled(!viewModel.canStart)

                Button {
                    Task {
                        await viewModel.stop()
                    }
                } label: {
                    Label("회의 전사 종료", systemImage: "stop.circle")
                }
                .disabled(!viewModel.canStop)
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("입력 source")
                        .foregroundStyle(.secondary)
                    Text(viewModel.selectedAudioSourceDescription)
                        .fontWeight(.medium)
                }
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
                if viewModel.selectedAudioSource == .fullMeeting {
                    GridRow {
                        Text("회의 전체")
                            .foregroundStyle(.secondary)
                        Text(viewModel.fullMeetingProviderStatus)
                            .fontWeight(.medium)
                            .textSelection(.enabled)
                    }
                }
            }

            if let guidanceText = viewModel.selectedAudioSourceGuidanceText {
                Text(guidanceText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if viewModel.shouldShowSpeechPermissionHelp {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.permissionHelpText)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack(spacing: 10) {
                        Button {
                            viewModel.openSpeechRecognitionSettings()
                        } label: {
                            Label("음성 인식 설정 열기", systemImage: "waveform")
                        }

                        if viewModel.selectedAudioSource.requiresMicrophone {
                            Button {
                                viewModel.openMicrophoneSettings()
                            } label: {
                                Label("마이크 설정 열기", systemImage: "mic")
                            }
                        }

                        if viewModel.selectedAudioSource.requiresSystemAudio {
                            Button {
                                viewModel.openScreenRecordingSettings()
                            } label: {
                                Label("화면 기록 설정 열기", systemImage: "display")
                            }
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
