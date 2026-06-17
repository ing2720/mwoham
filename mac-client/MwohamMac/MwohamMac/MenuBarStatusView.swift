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
        let presentation = MenuBarFloatingPresentation(
            provider: viewModel,
            isFloatingWidgetVisible: floatingWidgetController.isVisible
        )

        VStack(alignment: .leading) {
            StatusBadge(state: presentation.backendState, compact: true)
            if let backendDetail = presentation.backendDetail {
                Text(backendDetail)
            }
            StatusBadge(state: presentation.recordingState, compact: true)
            Text("기록 시간: \(presentation.recordingElapsedTimeText)")
            StatusBadge(state: presentation.devTrackingState, compact: true)

            Divider()

            RecordingControl(
                viewModel: viewModel.recording,
                style: .menu
            )

            Divider()

            Button(presentation.quickActions.openMainWindowTitle) {
                openWindow(id: "main")
                NSApplication.shared.activate()
            }

            Button(presentation.quickActions.floatingWidgetTitle) {
                floatingWidgetController.toggle(viewModel: viewModel)
            }

            Button(presentation.quickActions.openDashboardTitle) {
                viewModel.openDashboard()
            }

            Button(presentation.quickActions.refreshTitle) {
                Task {
                    await viewModel.refresh()
                }
            }
            .disabled(!presentation.quickActions.canRefresh)

            Divider()

            Button(presentation.quickActions.quitTitle) {
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
