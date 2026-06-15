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
                    Text(viewModel.sttInputSourceSummary)
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
                        state: viewModel.sttDisplayState,
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
                GridRow {
                    Text("마지막 처리 결과")
                        .foregroundStyle(.secondary)
                    Text(viewModel.sttResultSummary.resultText)
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("fallback")
                        .foregroundStyle(.secondary)
                    Text(viewModel.sttResultSummary.fallbackText)
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("처리 시간")
                        .foregroundStyle(.secondary)
                    Text(viewModel.sttResultSummary.processingTimeText)
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("Whisper chunk")
                        .foregroundStyle(.secondary)
                    Text(viewModel.sttResultSummary.chunkSummaryText)
                        .fontWeight(.medium)
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
                    WhisperDiagnosticsView(
                        summary: viewModel.sttResultSummary,
                        showsDebugExportPath:
                            viewModel.whisperDebugAudioExportEnabled
                    )
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
                    message: viewModel.permissionErrorMessage
                        ?? "설정 화면에서 관련 시스템 설정을 열 수 있습니다.",
                    title: "권한 확인이 필요합니다"
                )
            }

            if !viewModel.shouldShowSpeechPermissionHelp,
               let sttErrorMessage = viewModel.sttErrorMessage {
                ErrorBanner(
                    message: sttErrorMessage,
                    title: "STT 처리 실패"
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

private struct WhisperDiagnosticsView: View {
    let summary: STTResultSummary
    let showsDebugExportPath: Bool

    var body: some View {
        if !summary.didComplete {
            EmptyStateView(
                title: "Whisper 진단 정보가 없습니다",
                message: "회의 전체 전사를 종료하면 source별 처리 결과가 표시됩니다.",
                systemImage: "waveform.badge.magnifyingglass"
            )
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(summary.sourceDiagnostics) { diagnostic in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(diagnostic.sourceLabel)
                            .font(.headline)

                        LabeledContent("처리 결과") {
                            Text(sourceResultText(diagnostic))
                        }
                        LabeledContent("chunk") {
                            Text(
                                "전체 \(diagnostic.chunkCount)개 / "
                                    + "채택 \(diagnostic.acceptedChunkCount)개 / "
                                    + "제외 \(diagnostic.rejectedChunkCount)개"
                            )
                        }
                        LabeledContent("처리 시간") {
                            Text(processingTimeText(diagnostic))
                        }

                        rejectReasonSummary(diagnostic)

                        if showsDebugExportPath,
                           let debugExportPath = diagnostic.debugExportPath {
                            LabeledContent("debug 오디오") {
                                Text(debugExportPath)
                                    .textSelection(.enabled)
                                    .truncationMode(.middle)
                            }
                        }

                        if let failureReason = diagnostic.failureReason {
                            ErrorBanner(
                                message: failureReason,
                                title: "\(diagnostic.sourceLabel) 처리 실패"
                            )
                        }
                    }

                    if diagnostic.id != summary.sourceDiagnostics.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rejectReasonSummary(
        _ diagnostic: STTSourceDiagnostic
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("제외 사유")
                .font(.subheadline)
                .fontWeight(.semibold)

            let knownReasons = STTRejectReasonLabel.orderedKeys.filter {
                diagnostic.rejectReasons[$0] != nil
            }
            let otherReasons = diagnostic.rejectReasons.keys
                .filter { !STTRejectReasonLabel.orderedKeys.contains($0) }
                .sorted()
            let reasons = knownReasons + otherReasons

            if reasons.isEmpty {
                Text("제외된 chunk 없음")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(reasons, id: \.self) { reason in
                    LabeledContent(STTRejectReasonLabel.label(for: reason)) {
                        Text("\(diagnostic.rejectReasons[reason] ?? 0)개")
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private func sourceResultText(
        _ diagnostic: STTSourceDiagnostic
    ) -> String {
        guard diagnostic.wasAttempted else {
            return "처리하지 않음"
        }
        return diagnostic.wasIncluded ? "최종 전사에 포함됨" : "최종 전사에서 제외됨"
    }

    private func processingTimeText(
        _ diagnostic: STTSourceDiagnostic
    ) -> String {
        guard let processingSeconds = diagnostic.processingSeconds else {
            return "확인할 수 없음"
        }
        return String(format: "%.2f초", processingSeconds)
    }
}
