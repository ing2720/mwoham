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

            if viewModel.connectionState.isError {
                Text("로컬 서버 확인: \(viewModel.backendAddressText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 6) {
                FloatingStatusBadgeRow(
                    title: "현재 기록 상태",
                    state: viewModel.recordingState
                )
                FloatingStatusRow(title: "기록 시간", value: viewModel.recordingElapsedTime)
                FloatingStatusBadgeRow(
                    title: "활성 창 추적",
                    state: viewModel.activeWindowTrackingState
                )
                FloatingStatusBadgeRow(title: "OCR 상태", state: viewModel.ocrState)
                FloatingStatusBadgeRow(
                    title: "Dev Tracking",
                    state: viewModel.devTrackingState
                )
                FloatingStatusRow(title: "현재 앱", value: viewModel.currentApp)
                FloatingStatusRow(title: "현재 창", value: viewModel.currentWindow)
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
            StatusBadge(state: viewModel.recordingState, compact: true)

            Text(collapsedDetailText)
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
            StatusBadge(state: viewModel.connectionState, compact: true)

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

    private var collapsedDetailText: String {
        if viewModel.connectionState.isError {
            return "연결 실패"
        }

        if viewModel.isPrivateAppActive {
            return "비공개"
        }

        return "\(viewModel.recordingElapsedTime) · \(viewModel.shortDevTrackingStatus)"
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
