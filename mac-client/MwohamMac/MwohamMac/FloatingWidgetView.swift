//
//  FloatingWidgetView.swift
//  MwohamMac
//

import AppKit
import SwiftUI

struct FloatingWidgetView: View {
    @ObservedObject var viewModel: BackendStatusViewModel
    @State private var isCollapsed = false
    @Environment(\.openWindow) private var openWindow

    private var presentation: MenuBarFloatingPresentation {
        MenuBarFloatingPresentation(
            provider: viewModel,
            isFloatingWidgetVisible: true
        )
    }

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

            if presentation.backendState.isError {
                Text(presentation.backendDetail ?? "연결 실패")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 6) {
                FloatingStatusRow(
                    title: "현재 앱",
                    value: presentation.currentAppText
                )
                FloatingStatusRow(
                    title: "현재 창",
                    value: presentation.currentWindowText
                )
                FloatingStatusBadgeRow(
                    title: presentation.ocrTitle,
                    state: presentation.ocrState
                )
                FloatingDevTrackingRow(presentation: presentation)
            }

            Divider()
            RecordingControl(
                viewModel: viewModel.recording,
                fillsWidth: true
            )

            HStack(spacing: 8) {
                PrimaryActionButton(
                    title: presentation.controlActions.devTrackingToggleLabel,
                    systemImage: "point.3.connected.trianglepath.dotted",
                    isDisabled:
                        presentation.controlActions
                            .isDevTrackingToggleDisabled,
                    fillsWidth: true
                ) {
                    if viewModel.activityTracking.isDevTrackingRunning {
                        viewModel.activityTracking.stopDevTracking()
                    } else {
                        viewModel.activityTracking.startDevTracking()
                    }
                }

                PrimaryActionButton(
                    title: presentation.controlActions.meetingModeToggleLabel,
                    systemImage: "waveform.circle",
                    isDisabled:
                        presentation.controlActions
                            .isMeetingModeToggleDisabled,
                    fillsWidth: true
                ) {
                    await toggleMeetingMode()
                }
            }

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                    NSApplication.shared.activate()
                } label: {
                    Label(
                        presentation.quickActions.openMainWindowTitle,
                        systemImage: "macwindow"
                    )
                    .frame(maxWidth: .infinity)
                }

                Button {
                    viewModel.openDashboard()
                } label: {
                    Label(
                        presentation.quickActions.openDashboardTitle,
                        systemImage: "safari"
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14)
        .frame(width: 330, height: 360, alignment: .topLeading)
    }

    private var collapsedView: some View {
        HStack(spacing: 8) {
            StatusBadge(state: presentation.recordingState, compact: true)

            Text(presentation.collapsedDetailText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            RecordingControl(
                viewModel: viewModel.recording,
                style: .compact
            )

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
        HStack(spacing: 8) {
            StatusBadge(state: presentation.backendState, compact: true)
            StatusBadge(state: presentation.recordingState, compact: true)

            Text(presentation.recordingElapsedTimeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .disabled(true)
            .help("\(presentation.widgetSettingsLabel) 준비 중")

            Button {
                Task {
                    await viewModel.refresh()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!presentation.quickActions.canRefresh)

            Button {
                isCollapsed.toggle()
            } label: {
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
            .help(presentation.widgetCompactToggleLabel)
        }
    }

    private func toggleMeetingMode() async {
        if viewModel.meetingTranscription.state.isRunning {
            await viewModel.meetingTranscription.stop()
            return
        }
        if viewModel.meetingTranscription.canChangeAudioSource {
            viewModel.meetingTranscription.selectedAudioSource = .fullMeeting
        }
        await viewModel.meetingTranscription.start()
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

private struct FloatingDevTrackingRow: View {
    let presentation: MenuBarFloatingPresentation

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(presentation.devTrackingTitle)
                .foregroundStyle(.secondary)
            Spacer()
            DevTrackingCompactBadge(
                text: presentation.devTrackingDisplayText,
                state: presentation.devTrackingBadgeState
            )
        }
        .font(.footnote)
    }
}

private struct DevTrackingCompactBadge: View {
    let text: String
    let state: MenuBarFloatingPresentation.DevTrackingBadgeState

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .accessibilityLabel(text)
    }

    private var color: Color {
        switch state {
        case .running:
            return .green
        case .stopping:
            return .orange
        case .stopped:
            return .secondary
        case .error:
            return .red
        }
    }
}

private struct FloatingStatusBadgeRow<State: StatusPresentable>: View {
    let title: String
    let state: State

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            StatusBadge(state: state, compact: true)
                .lineLimit(1)
        }
        .font(.footnote)
    }
}
