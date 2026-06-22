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
            Button(presentation.controlActions.recordingStartLabel) {
                Task {
                    await viewModel.recording.start()
                }
            }
            .disabled(presentation.controlActions.isRecordingStartDisabled)

            Button(presentation.controlActions.recordingPauseResumeLabel) {
                Task {
                    if viewModel.recording.state == .paused {
                        await viewModel.recording.resume()
                    } else {
                        await viewModel.recording.pause()
                    }
                }
            }
            .disabled(
                presentation.controlActions.isRecordingPauseResumeDisabled
            )

            Button(
                presentation.controlActions.recordingStopLabel,
                role: .destructive
            ) {
                Task {
                    await viewModel.recording.stop()
                }
            }
            .disabled(presentation.controlActions.isRecordingStopDisabled)

            Divider()

            Button(presentation.controlActions.devTrackingToggleLabel) {
                if viewModel.activityTracking.isDevTrackingRunning {
                    viewModel.activityTracking.stopDevTracking()
                } else {
                    viewModel.activityTracking.startDevTracking()
                }
            }
            .disabled(presentation.controlActions.isDevTrackingToggleDisabled)

            Button(presentation.controlActions.meetingModeToggleLabel) {
                Task {
                    await toggleMeetingMode()
                }
            }
            .disabled(presentation.controlActions.isMeetingModeToggleDisabled)

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

            Divider()

            Button(presentation.controlActions.restartLabel) {
                restartApp()
            }

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

    private func toggleMeetingMode() async {
        if viewModel.meetingTranscription.state.isRunning {
            await viewModel.meetingTranscription.stop()
            return
        }
        if viewModel.meetingTranscription.canChangeAudioSource {
            viewModel.meetingTranscription.selectedAudioSource = .fullMeeting
        }
        await viewModel.meetingTranscription.start()
    }

    private func restartApp() {
        AppRelauncher.relaunch()
    }

}
