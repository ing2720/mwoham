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
                PrimaryActionButton(
                    title: "회의 전사 시작",
                    systemImage: "mic.circle",
                    isDisabled: !viewModel.canStart
                ) {
                    await viewModel.start()
                }

                PrimaryActionButton(
                    title: "회의 전사 종료",
                    systemImage: "stop.circle",
                    role: .destructive,
                    isDisabled: !viewModel.canStop
                ) {
                    await viewModel.stop()
                }
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
                    StatusBadge(state: viewModel.state, compact: true)
                }
                GridRow {
                    Text("STT 엔진")
                        .foregroundStyle(.secondary)
                    StatusBadge(
                        state: viewModel.sttEngineState,
                        compact: true
                    )
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

            StatusCard("최근 전사", systemImage: "text.quote") {
                if viewModel.latestTranscriptText.isEmpty {
                    EmptyStateView(
                        title: "최근 전사가 없습니다",
                        message: "회의 전사를 시작하면 결과가 여기에 표시됩니다.",
                        systemImage: "waveform"
                    )
                } else {
                    Text(viewModel.latestTranscriptText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
            }

            StatusCard("소스별 처리 결과", systemImage: "list.bullet.rectangle") {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: 20,
                    verticalSpacing: 8
                ) {
                    ProviderStatusRow(
                        title: "마이크",
                        state: viewModel.microphoneState
                    )
                    ProviderStatusRow(
                        title: "시스템 오디오",
                        state: viewModel.systemAudioState
                    )
                    ProviderStatusRow(
                        title: "회의 전체",
                        state: viewModel.fullMeetingState
                    )
                }
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
                ErrorBanner(
                    message: "설정 화면에서 관련 시스템 설정을 열 수 있습니다.",
                    title: "권한 확인이 필요합니다"
                )
            }
        }
    }
}

private struct ProviderStatusRow: View {
    let title: String
    let state: CollectorState

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            StatusBadge(state: state, compact: true)
        }
    }
}
