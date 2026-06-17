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

    private static let defaultSize = NSSize(width: 330, height: 360)
    private static let minimumSize = NSSize(width: 250, height: 210)
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
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.defaultSize.width,
                height: Self.defaultSize.height
            ),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView,
                .utilityWindow,
            ],
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
        panel.minSize = Self.minimumSize
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
