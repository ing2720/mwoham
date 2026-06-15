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
            StatusBadge(state: viewModel.connectionState, compact: true)
            if viewModel.connectionState.isError {
                Text("로컬 서버가 실행 중인지 확인해 주세요.")
                Text("주소: \(viewModel.backendAddressText)")
            }
            StatusBadge(state: viewModel.recordingState, compact: true)
            Text("기록 시간: \(viewModel.recordingElapsedTime)")
            StatusBadge(state: viewModel.devTrackingState, compact: true)

            Divider()

            RecordingControl(
                viewModel: viewModel.recording,
                style: .menu
            )

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
