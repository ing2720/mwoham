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
    private static let minimumContentSize = NSSize(width: 214, height: 80)
    private static let compactSize = minimumContentSize
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
            panel.contentView = NSHostingView(
                rootView: makeFloatingWidgetView(viewModel: viewModel)
            )
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
        panel.contentMinSize = Self.minimumContentSize
        panel.minSize = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)
        ).size
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: makeFloatingWidgetView(viewModel: viewModel)
        )
        panel.center()
        panel.orderFrontRegardless()

        self.panel = panel
        isVisible = true
    }

    func close() {
        panel?.close()
        isVisible = false
    }

    func resize(to target: FloatingWidgetResizeTarget) {
        switch target {
        case .compact:
            resize(to: Self.compactSize)
        case .standard:
            resize(to: Self.defaultSize)
        }
    }

    private func makeFloatingWidgetView(
        viewModel: BackendStatusViewModel
    ) -> FloatingWidgetView {
        FloatingWidgetView(
            viewModel: viewModel,
            onResizeRequest: { [weak self] target in
                Task { @MainActor in
                    self?.resize(to: target)
                }
            }
        )
    }

    private func resize(to size: NSSize) {
        guard let panel else {
            return
        }
        let currentFrame = panel.frame
        let targetSize = NSSize(
            width: max(size.width, Self.minimumContentSize.width),
            height: max(size.height, Self.minimumContentSize.height)
        )
        let newOrigin = NSPoint(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetSize.height
        )
        panel.setFrame(
            NSRect(origin: newOrigin, size: targetSize),
            display: true,
            animate: true
        )
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            isVisible = false
        }
    }
}
