//
//  FloatingWidgetController.swift
//  MwohamMac
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class FloatingWidgetController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false

    private var panel: NSPanel?

    func toggle(viewModel: BackendStatusViewModel) {
        if isVisible {
            close()
        } else {
            open(viewModel: viewModel)
        }
    }

    func open(viewModel: BackendStatusViewModel) {
        if let panel {
            panel.contentView = NSHostingView(rootView: FloatingWidgetView(viewModel: viewModel))
            panel.orderFrontRegardless()
            isVisible = true
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 250),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Mwoham"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FloatingWidgetView(viewModel: viewModel))
        panel.center()
        panel.orderFrontRegardless()

        self.panel = panel
        isVisible = true
    }

    func close() {
        panel?.close()
        isVisible = false
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            isVisible = false
        }
    }
}
