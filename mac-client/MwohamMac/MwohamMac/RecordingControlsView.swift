//
//  RecordingControlsView.swift
//  MwohamMac
//

import SwiftUI

struct RecordingControlsView: View {
    @ObservedObject var viewModel: RecordingViewModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await viewModel.start()
                }
            } label: {
                Label("기록 시작", systemImage: "record.circle")
            }
            .disabled(!viewModel.canStart)

            Button {
                Task {
                    await viewModel.pause()
                }
            } label: {
                Label("일시정지", systemImage: "pause.circle")
            }
            .disabled(!viewModel.canPause)

            Button {
                Task {
                    await viewModel.resume()
                }
            } label: {
                Label("재개", systemImage: "play.circle")
            }
            .disabled(!viewModel.canResume)

            Button {
                Task {
                    await viewModel.stop()
                }
            } label: {
                Label("기록 종료", systemImage: "stop.circle")
            }
            .disabled(!viewModel.canStop)
        }
    }
}
