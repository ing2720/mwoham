//
//  RecordingControlsView.swift
//  MwohamMac
//

import SwiftUI

struct RecordingControlsView: View {
    @ObservedObject var viewModel: BackendStatusViewModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await viewModel.startRecording()
                }
            } label: {
                Label("기록 시작", systemImage: "record.circle")
            }
            .disabled(!viewModel.canStartRecording)

            Button {
                Task {
                    await viewModel.pauseRecording()
                }
            } label: {
                Label("일시정지", systemImage: "pause.circle")
            }
            .disabled(!viewModel.canPauseRecording)

            Button {
                Task {
                    await viewModel.resumeRecording()
                }
            } label: {
                Label("재개", systemImage: "play.circle")
            }
            .disabled(!viewModel.canResumeRecording)

            Button {
                Task {
                    await viewModel.stopRecording()
                }
            } label: {
                Label("기록 종료", systemImage: "stop.circle")
            }
            .disabled(!viewModel.canStopRecording)
        }
    }
}
