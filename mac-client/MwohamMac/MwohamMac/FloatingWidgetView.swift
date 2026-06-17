//
//  FloatingWidgetView.swift
//  MwohamMac
//

import SwiftUI

struct FloatingWidgetView: View {
    @ObservedObject var viewModel: BackendStatusViewModel
    @State private var isCollapsed = false

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
                FloatingStatusBadgeRow(
                    title: "현재 기록 상태",
                    state: presentation.recordingState
                )
                FloatingStatusRow(
                    title: "기록 시간",
                    value: presentation.recordingElapsedTimeText
                )
                FloatingStatusBadgeRow(
                    title: presentation.activeWindowTrackingTitle,
                    state: presentation.activeWindowTrackingState
                )
                FloatingStatusBadgeRow(
                    title: presentation.ocrTitle,
                    state: presentation.ocrState
                )
                FloatingStatusBadgeRow(
                    title: presentation.devTrackingTitle,
                    state: presentation.devTrackingState
                )
                FloatingStatusRow(
                    title: "현재 앱",
                    value: presentation.currentAppText
                )
                FloatingStatusRow(
                    title: "현재 창",
                    value: presentation.currentWindowText
                )
            }

            Divider()
            RecordingControl(
                viewModel: viewModel.recording,
                fillsWidth: true
            )
        }
        .padding(14)
        .frame(width: 300, height: 290, alignment: .topLeading)
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
        HStack {
            StatusBadge(state: presentation.backendState, compact: true)

            Spacer()

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
            .help(isCollapsed ? "펼치기" : "접기")
        }
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
