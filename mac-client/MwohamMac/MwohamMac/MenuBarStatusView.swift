//
//  MenuBarStatusView.swift
//  MwohamMac
//

import AppKit
import Combine
import SwiftUI

struct MenuBarStatusView: View {
    @ObservedObject var viewModel: BackendStatusViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading) {
            Text("백엔드: \(viewModel.isConnected ? "연결됨" : "연결 실패")")
            Text("현재 기록 상태: \(viewModel.recordingStatus)")
            Text("기록 시간: \(viewModel.recordingElapsedTime)")

            Divider()

            Button("기록 시작") {
                Task {
                    await viewModel.startRecording()
                }
            }
            .disabled(!viewModel.canStartRecording)

            Button("일시정지") {
                Task {
                    await viewModel.pauseRecording()
                }
            }
            .disabled(!viewModel.canPauseRecording)

            Button("재개") {
                Task {
                    await viewModel.resumeRecording()
                }
            }
            .disabled(!viewModel.canResumeRecording)

            Button("기록 종료") {
                Task {
                    await viewModel.stopRecording()
                }
            }
            .disabled(!viewModel.canStopRecording)

            Divider()

            Button("메인 창 열기") {
                openWindow(id: "main")
                NSApplication.shared.activate()
            }

            Button("대시보드 열기") {
                openDashboard()
            }

            Button("새로고침") {
                Task {
                    await viewModel.refresh()
                }
            }
            .disabled(viewModel.isLoading)

            Divider()

            Button("앱 종료") {
                NSApplication.shared.terminate(nil)
            }
        }
        .task {
            await viewModel.refresh()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            viewModel.updateElapsedTime()
        }
    }

    private func openDashboard() {
        guard let url = URL(string: "http://127.0.0.1:8765/dashboard") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
