//
//  MenuBarStatusView.swift
//  MwohamMac
//

import AppKit
import Combine
import SwiftUI

struct MenuBarStatusView: View {
    @ObservedObject var viewModel: BackendStatusViewModel
    @ObservedObject var floatingWidgetController: FloatingWidgetController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading) {
            Text(viewModel.isConnected ? "백엔드 연결됨" : "백엔드 연결 실패")
            if !viewModel.isConnected {
                Text("로컬 서버가 실행 중인지 확인해 주세요.")
                Text("주소: \(viewModel.backendAddressText)")
            }
            Text("현재 기록 상태: \(viewModel.recordingStatus)")
            Text("기록 시간: \(viewModel.recordingElapsedTime)")
            Text("Dev Tracking: \(viewModel.shortDevTrackingStatus)")

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

            Button(floatingWidgetController.isVisible ? "플로팅 위젯 닫기" : "플로팅 위젯 열기") {
                floatingWidgetController.toggle(viewModel: viewModel)
            }

            Button("대시보드 열기") {
                viewModel.openDashboard()
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
            viewModel.startActiveWindowTracking()
            viewModel.startOCRCollection()
            await viewModel.refresh()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            viewModel.updateElapsedTime()
        }
    }

}
