//
//  FloatingWidgetView.swift
//  MwohamMac
//

import SwiftUI

struct FloatingWidgetView: View {
    @ObservedObject var viewModel: BackendStatusViewModel
    @State private var isCollapsed = false

    var body: some View {
        Group {
            if isCollapsed {
                collapsedView
            } else {
                expandedView
            }
        }
        .background(.regularMaterial)
    }

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView

            VStack(alignment: .leading, spacing: 6) {
                FloatingStatusRow(title: "현재 기록 상태", value: viewModel.recordingStatus)
                FloatingStatusRow(title: "기록 시간", value: viewModel.recordingElapsedTime)
                FloatingStatusRow(title: "활성 창 추적", value: viewModel.activeWindowTrackingStatus)
                FloatingStatusRow(title: "현재 앱", value: viewModel.currentApp)
                FloatingStatusRow(title: "현재 창", value: viewModel.currentWindow)
            }

            Divider()
            recordingControls
        }
        .padding(14)
        .frame(width: 300, height: 270, alignment: .topLeading)
    }

    private var collapsedView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isConnected ? .green : .red)
                .frame(width: 8, height: 8)
                .accessibilityLabel(viewModel.isConnected ? "백엔드 연결됨" : "백엔드 연결 실패")

            Text(viewModel.recordingStatus)
                .font(.footnote)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(minWidth: 46, alignment: .leading)

            Text(viewModel.recordingElapsedTime)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            collapsedRecordingControl

            Button {
                isCollapsed = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("펼치기")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 300, height: 38, alignment: .center)
    }

    private var headerView: some View {
        HStack {
            Label(
                viewModel.isConnected ? "백엔드 연결됨" : "백엔드 연결 실패",
                systemImage: viewModel.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .foregroundStyle(viewModel.isConnected ? .green : .red)

            Spacer()

            Button {
                Task {
                    await viewModel.refresh()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isLoading)

            Button {
                isCollapsed.toggle()
            } label: {
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
            .help(isCollapsed ? "펼치기" : "접기")
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        switch viewModel.recordingState {
        case "stopped":
            recordingButton(
                "기록 시작",
                systemImage: "record.circle",
                isDisabled: !viewModel.canStartRecording
            ) {
                await viewModel.startRecording()
            }
        case "active":
            HStack(spacing: 8) {
                recordingButton(
                    "일시정지",
                    systemImage: "pause.circle",
                    isDisabled: !viewModel.canPauseRecording
                ) {
                    await viewModel.pauseRecording()
                }

                recordingButton(
                    "기록 종료",
                    systemImage: "stop.circle",
                    isDisabled: !viewModel.canStopRecording
                ) {
                    await viewModel.stopRecording()
                }
            }
        case "paused":
            HStack(spacing: 8) {
                recordingButton(
                    "재개",
                    systemImage: "play.circle",
                    isDisabled: !viewModel.canResumeRecording
                ) {
                    await viewModel.resumeRecording()
                }

                recordingButton(
                    "기록 종료",
                    systemImage: "stop.circle",
                    isDisabled: !viewModel.canStopRecording
                ) {
                    await viewModel.stopRecording()
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var collapsedRecordingControl: some View {
        switch viewModel.recordingState {
        case "stopped":
            compactRecordingButton("기록 시작", isDisabled: !viewModel.canStartRecording) {
                await viewModel.startRecording()
            }
        case "active":
            compactRecordingButton("일시정지", isDisabled: !viewModel.canPauseRecording) {
                await viewModel.pauseRecording()
            }
        case "paused":
            compactRecordingButton("재개", isDisabled: !viewModel.canResumeRecording) {
                await viewModel.resumeRecording()
            }
        default:
            EmptyView()
        }
    }

    private func recordingButton(
        _ title: String,
        systemImage: String,
        isDisabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task {
                await action()
            }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .disabled(isDisabled)
    }

    private func compactRecordingButton(
        _ title: String,
        isDisabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button(title) {
            Task {
                await action()
            }
        }
        .controlSize(.small)
        .disabled(isDisabled)
    }
}

private struct FloatingStatusRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.footnote)
    }
}
