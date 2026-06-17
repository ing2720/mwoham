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
        GeometryReader { proxy in
            let layoutMode = resolvedLayoutMode(for: proxy.size)
            content(for: layoutMode)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .background(.regularMaterial)
        }
    }

    @ViewBuilder
    private func content(
        for layoutMode: MenuBarFloatingPresentation.FloatingWidgetLayoutMode
    ) -> some View {
        switch layoutMode {
        case .compact:
            compactView
        case .normal:
            normalView
        case .expanded:
            expandedView
        }
    }

    private func resolvedLayoutMode(
        for size: CGSize
    ) -> MenuBarFloatingPresentation.FloatingWidgetLayoutMode {
        if isCollapsed {
            return .compact
        }
        return MenuBarFloatingPresentation.FloatingWidgetLayoutMode.mode(
            width: Double(size.width),
            height: Double(size.height)
        )
    }

    private var compactView: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerView(layoutMode: .compact)

            Text(presentation.compactCurrentActivityText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if presentation.shouldShowDevTrackingInCompact {
                DevTrackingCompactBadge(
                    text: presentation.devTrackingDisplayText,
                    state: presentation.devTrackingBadgeState
                )
            }

            HStack(spacing: 8) {
                RecordingControl(
                    viewModel: viewModel.recording,
                    style: .compact
                )

                Button {
                    openWindow(id: "main")
                    NSApplication.shared.activate()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .help(presentation.quickActions.openMainWindowTitle)
            }
        }
        .padding(10)
    }

    private var normalView: some View {
        widgetContent(
            layoutMode: .normal,
            rowSpacing: 6,
            sectionSpacing: 12,
            showsExpandedStatus: false
        )
    }

    private var expandedView: some View {
        widgetContent(
            layoutMode: .expanded,
            rowSpacing: 10,
            sectionSpacing: 16,
            showsExpandedStatus: true
        )
    }

    private func widgetContent(
        layoutMode: MenuBarFloatingPresentation.FloatingWidgetLayoutMode,
        rowSpacing: CGFloat,
        sectionSpacing: CGFloat,
        showsExpandedStatus: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            headerView(layoutMode: layoutMode)

            if presentation.backendState.isError {
                Text(presentation.backendDetail ?? "연결 실패")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: rowSpacing) {
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

            if showsExpandedStatus {
                FloatingStatusBadgeRow(
                    title: presentation.activeWindowTrackingTitle,
                    state: presentation.activeWindowTrackingState
                )
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
        .padding(layoutMode == .expanded ? 18 : 14)
    }

    private func headerView(
        layoutMode: MenuBarFloatingPresentation.FloatingWidgetLayoutMode
    ) -> some View {
        HStack(spacing: 8) {
            StatusBadge(state: presentation.backendState, compact: true)
            StatusBadge(state: presentation.recordingState, compact: true)

            Text(presentation.recordingElapsedTimeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if layoutMode != .compact {
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
            }

            Button {
                isCollapsed.toggle()
            } label: {
                Image(
                    systemName:
                        layoutMode == .compact ? "arrow.up.left.and.arrow.down.right" : "chevron.up"
                )
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
