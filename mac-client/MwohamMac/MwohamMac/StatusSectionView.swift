//
//  StatusSectionView.swift
//  MwohamMac
//

import SwiftUI

struct StatusSectionView: View {
    @ObservedObject var viewModel: BackendStatusViewModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
            StatusRow(title: "현재 기록 상태", value: viewModel.recordingState.label)
            StatusRow(title: "기록 시간", value: viewModel.recordingElapsedTime)
            StatusRow(title: "활성 창 추적", value: viewModel.activeWindowTrackingState.label)
            StatusRow(title: "OCR 상태", value: viewModel.ocrState.label)
            StatusRow(title: "Dev Tracking", value: viewModel.devTrackingState.label)
            StatusRow(title: "회의 모드", value: viewModel.meetingMode)
            StatusRow(title: "현재 앱", value: viewModel.currentApp)
            StatusRow(title: "현재 창", value: viewModel.currentWindow)
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
