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
                    Text("입력 소스")
                        .foregroundStyle(.secondary)
                    Text(viewModel.selectedAudioSourceDescription)
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("전사 상태")
                        .foregroundStyle(.secondary)
                    Text(viewModel.state.label)
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("STT 엔진")
                        .foregroundStyle(.secondary)
                    Text(viewModel.sttEngineState.label)
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("회의 모드")
                        .foregroundStyle(.secondary)
                    Text(viewModel.meetingMode)
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                }
                if viewModel.selectedAudioSource == .fullMeeting {
                    GridRow {
                        Text("Whisper 입력")
                            .foregroundStyle(.secondary)
                        Text(viewModel.whisperInputSources)
                            .fontWeight(.medium)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("회의 전체")
                            .foregroundStyle(.secondary)
                        Text(viewModel.fullMeetingState.label)
                            .fontWeight(.medium)
                            .textSelection(.enabled)
                    }
                }
            }

            GroupBox("최근 전사") {
                Text(latestTranscriptText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }

            GroupBox("소스별 처리 결과") {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: 20,
                    verticalSpacing: 8
                ) {
                    ProviderStatusRow(
                        title: "마이크",
                        value: viewModel.microphoneState.label
                    )
                    ProviderStatusRow(
                        title: "시스템 오디오",
                        value: viewModel.systemAudioState.label
                    )
                    ProviderStatusRow(
                        title: "회의 전체",
                        value: viewModel.fullMeetingState.label
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            if viewModel.selectedAudioSource == .fullMeeting {
                DisclosureGroup("Whisper 상세 정보") {
                    Text(viewModel.whisperDiagnostics)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, 8)
                }
            }

            if let guidanceText = viewModel.selectedAudioSourceGuidanceText {
                Text(guidanceText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if viewModel.shouldShowSpeechPermissionHelp {
                Text("권한 확인이 필요합니다. 설정 화면에서 관련 시스템 설정을 열 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var latestTranscriptText: String {
        viewModel.latestTranscriptText.isEmpty ? "아직 전사된 텍스트가 없습니다." : viewModel.latestTranscriptText
    }
}

private struct ProviderStatusRow: View {
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
