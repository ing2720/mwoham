//
//  StatusSectionView.swift
//  MwohamMac
//

import SwiftUI

struct StatusSectionView: View {
    @ObservedObject var viewModel: BackendStatusViewModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
            StatusRow(title: "현재 기록 상태", value: viewModel.recordingStatus)
            StatusRow(title: "기록 시간", value: viewModel.recordingElapsedTime)
            StatusRow(title: "활성 창 추적", value: viewModel.activeWindowTrackingStatus)
            StatusRow(title: "meeting_mode", value: viewModel.meetingMode)
            StatusRow(title: "current_app", value: viewModel.currentApp)
            StatusRow(title: "current_window", value: viewModel.currentWindow)
        }
    }
}

private struct StatusRow: View {
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
