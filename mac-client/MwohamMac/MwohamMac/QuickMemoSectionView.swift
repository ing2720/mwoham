//
//  QuickMemoSectionView.swift
//  MwohamMac
//

import AppKit
import SwiftUI

struct QuickMemoSectionView: View {
    @ObservedObject var viewModel: QuickMemoViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("빠른 메모")
                .font(.headline)

            MemoTextEditor(text: $viewModel.content) {
                Task {
                    await viewModel.save()
                }
            }
            .frame(minHeight: 70)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.quaternary)
            )

            HStack {
                Spacer()

                PrimaryActionButton(
                    title: "메모 저장",
                    systemImage: "square.and.arrow.down",
                    isDisabled: !viewModel.canSave
                ) {
                    await viewModel.save()
                }
            }

            Text(viewModel.statusMessage.isEmpty ? " " : viewModel.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MemoTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder

        let textView = KeyHandlingTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 70)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? KeyHandlingTextView else {
            return
        }

        textView.onSubmit = onSubmit

        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MemoTextEditor
        weak var textView: KeyHandlingTextView?

        init(_ parent: MemoTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            parent.text = textView.string
        }
    }

    final class KeyHandlingTextView: NSTextView {
        var onSubmit: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            let isReturnKey = event.keyCode == 36 || event.keyCode == 76
            let isShiftPressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)

            if isReturnKey && !isShiftPressed {
                onSubmit?()
                return
            }

            super.keyDown(with: event)
        }
    }
}
