//
//  ContentView.swift
//  MwohamMac
//
//  Created by a on 5/29/26.
//

import Combine
import AppKit
import SwiftUI

@MainActor
final class BackendStatusViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var isConnected = false
    @Published var recordingStatus = "-"
    @Published var recordingElapsedTime = "기록 중 아님"
    @Published var meetingMode = "-"
    @Published var currentApp = "-"
    @Published var currentWindow = "-"
    @Published var errorMessage: String?
    @Published var memoContent = ""
    @Published var memoStatusMessage = ""
    @Published var isSavingMemo = false

    private let localApiClient: LocalApiClient
    private var rawRecordingStatus = "unknown"
    private var sessionStartedAt: Date?
    private var statusElapsedSeconds: Int?
    private var statusReceivedAt: Date?

    init() {
        self.localApiClient = LocalApiClient()
    }

    init(localApiClient: LocalApiClient) {
        self.localApiClient = localApiClient
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil

        do {
            let snapshot = try await localApiClient.fetchSnapshot()
            applySnapshot(snapshot)
        } catch {
            isConnected = false
            rawRecordingStatus = "unknown"
            recordingStatus = "-"
            recordingElapsedTime = "기록 중 아님"
            meetingMode = "-"
            currentApp = "-"
            currentWindow = "-"
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func startRecording() async {
        await runRecordingAction(.start)
    }

    func pauseRecording() async {
        await runRecordingAction(.pause)
    }

    func resumeRecording() async {
        await runRecordingAction(.resume)
    }

    func stopRecording() async {
        await runRecordingAction(.stop)
    }

    func saveMemo() async {
        guard !isSavingMemo else {
            return
        }

        let trimmedContent = memoContent.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedContent.isEmpty else {
            memoStatusMessage = "메모 내용을 입력해 주세요."
            return
        }

        isSavingMemo = true
        memoStatusMessage = "메모 저장 중..."

        do {
            try await localApiClient.createMemo(content: trimmedContent)
            memoContent = ""
            memoStatusMessage = "메모가 저장되었습니다."

            let snapshot = try await localApiClient.fetchSnapshot()
            applySnapshot(snapshot)
        } catch {
            memoStatusMessage = "메모 저장에 실패했습니다: \(error.localizedDescription)"
            await refreshAfterFailedAction()
        }

        isSavingMemo = false
    }

    var canStartRecording: Bool {
        canUseControls && rawRecordingStatus == "stopped"
    }

    var canPauseRecording: Bool {
        canUseControls && rawRecordingStatus == "active"
    }

    var canResumeRecording: Bool {
        canUseControls && rawRecordingStatus == "paused"
    }

    var canStopRecording: Bool {
        canUseControls && (rawRecordingStatus == "active" || rawRecordingStatus == "paused")
    }

    var canSaveMemo: Bool {
        isConnected && !isSavingMemo
    }

    func updateElapsedTime() {
        recordingElapsedTime = makeElapsedTimeText(at: Date())
    }

    private func displayValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "없음"
        }

        return value
    }

    private var canUseControls: Bool {
        isConnected && !isLoading
    }

    private func runRecordingAction(_ action: RecordingAction) async {
        isLoading = true
        errorMessage = nil

        do {
            switch action {
            case .start:
                try await localApiClient.startRecording()
            case .pause:
                try await localApiClient.pauseRecording()
            case .resume:
                try await localApiClient.resumeRecording()
            case .stop:
                try await localApiClient.stopRecording()
            }

            let snapshot = try await localApiClient.fetchSnapshot()
            applySnapshot(snapshot)
        } catch {
            errorMessage = "\(action.errorTitle) 요청 실패: \(error.localizedDescription)"
            await refreshAfterFailedAction()
        }

        isLoading = false
    }

    private func refreshAfterFailedAction() async {
        do {
            let snapshot = try await localApiClient.fetchSnapshot()
            applySnapshot(snapshot)
        } catch {
            isConnected = false
        }
    }

    private func applySnapshot(_ snapshot: BackendSnapshot) {
        let receivedAt = Date()
        isConnected = snapshot.health.status == "ok"
        rawRecordingStatus = snapshot.status.status
        recordingStatus = snapshot.status.status
        sessionStartedAt = parseDate(snapshot.status.sessionStartedAt)
        statusElapsedSeconds = snapshot.status.elapsedSeconds
        statusReceivedAt = receivedAt
        recordingElapsedTime = makeElapsedTimeText(at: receivedAt)
        meetingMode = snapshot.status.meetingMode ? "켜짐" : "꺼짐"
        currentApp = displayValue(snapshot.status.currentApp)
        currentWindow = displayValue(snapshot.status.currentWindow)
    }

    private func makeElapsedTimeText(at now: Date) -> String {
        switch rawRecordingStatus {
        case "active":
            if let sessionStartedAt {
                return formatElapsedSeconds(Int(max(0, now.timeIntervalSince(sessionStartedAt))))
            }

            if let statusElapsedSeconds, let statusReceivedAt {
                let elapsedSinceStatus = Int(max(0, now.timeIntervalSince(statusReceivedAt)))
                return formatElapsedSeconds(statusElapsedSeconds + elapsedSinceStatus)
            }

            return "-"
        case "paused":
            if let statusElapsedSeconds {
                return formatElapsedSeconds(statusElapsedSeconds)
            }

            if let sessionStartedAt, let statusReceivedAt {
                return formatElapsedSeconds(Int(max(0, statusReceivedAt.timeIntervalSince(sessionStartedAt))))
            }

            return "-"
        default:
            return "기록 중 아님"
        }
    }

    private func formatElapsedSeconds(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 {
            return "\(totalSeconds)초"
        }

        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 {
            return "\(totalMinutes)분"
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return String(format: "%d시간 %02d분", hours, minutes)
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
    }
}

private enum RecordingAction {
    case start
    case pause
    case resume
    case stop

    var errorTitle: String {
        switch self {
        case .start:
            return "기록 시작"
        case .pause:
            return "일시정지"
        case .resume:
            return "재개"
        case .stop:
            return "기록 종료"
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = BackendStatusViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("로컬 백엔드 상태")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Label(
                        viewModel.isConnected ? "백엔드 연결됨" : "백엔드 연결 실패",
                        systemImage: viewModel.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(viewModel.isConnected ? .green : .red)
                }

                Spacer()

                Button {
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.startRecording()
                    }
                } label: {
                    Label("기록 시작", systemImage: "record.circle")
                }
                .disabled(!viewModel.canStartRecording)

                Button {
                    Task {
                        await viewModel.pauseRecording()
                    }
                } label: {
                    Label("일시정지", systemImage: "pause.circle")
                }
                .disabled(!viewModel.canPauseRecording)

                Button {
                    Task {
                        await viewModel.resumeRecording()
                    }
                } label: {
                    Label("재개", systemImage: "play.circle")
                }
                .disabled(!viewModel.canResumeRecording)

                Button {
                    Task {
                        await viewModel.stopRecording()
                    }
                } label: {
                    Label("기록 종료", systemImage: "stop.circle")
                }
                .disabled(!viewModel.canStopRecording)
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                StatusRow(title: "현재 기록 상태", value: viewModel.recordingStatus)
                StatusRow(title: "기록 시간", value: viewModel.recordingElapsedTime)
                StatusRow(title: "meeting_mode", value: viewModel.meetingMode)
                StatusRow(title: "current_app", value: viewModel.currentApp)
                StatusRow(title: "current_window", value: viewModel.currentWindow)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("빠른 메모")
                    .font(.headline)

                MemoTextEditor(text: $viewModel.memoContent) {
                    Task {
                        await viewModel.saveMemo()
                    }
                }
                    .frame(minHeight: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    )

                HStack {
                    Spacer()

                    Button {
                        Task {
                            await viewModel.saveMemo()
                        }
                    } label: {
                        Label("메모 저장", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!viewModel.canSaveMemo)
                }

                Text(viewModel.memoStatusMessage.isEmpty ? " " : viewModel.memoStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.isLoading {
                ProgressView("상태를 확인하는 중")
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 460, minHeight: 390, alignment: .topLeading)
        .padding(24)
        .task {
            await viewModel.refresh()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            viewModel.updateElapsedTime()
        }
    }
}

private struct StatusRow: View {
    let title: String
    let value: String

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
                .textSelection(.enabled)
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
