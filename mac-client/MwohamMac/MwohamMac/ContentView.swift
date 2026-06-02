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
    @Published var activeWindowTrackingStatus = "활성 창 추적 대기 중"
    @Published var isPrivateAppActive = false
    @Published var ocrStatus = "OCR 대기 중"
    @Published var currentMeeting: MeetingResponse?
    @Published var transcriptionStatus = "회의 전사 대기 중"
    @Published var latestTranscriptText = ""

    private let localApiClient: LocalApiClient
    private let activeWindowCollector: ActiveWindowCollector
    private let ocrCollector: OCRCollector
    private let speechTranscriptionProvider: SpeechTranscriptionProvider
    private var rawRecordingStatus = "unknown"
    private var sessionStartedAt: Date?
    private var statusElapsedSeconds: Int?
    private var statusReceivedAt: Date?
    private var lastSubmittedTranscriptText = ""
    private var isStoppingMeetingTranscription = false

    init() {
        let localApiClient = LocalApiClient()
        self.localApiClient = localApiClient
        self.activeWindowCollector = ActiveWindowCollector(localApiClient: localApiClient)
        self.ocrCollector = OCRCollector(localApiClient: localApiClient)
        self.speechTranscriptionProvider = AppleSpeechTranscriptionProvider()
    }

    init(
        localApiClient: LocalApiClient,
        speechTranscriptionProvider: SpeechTranscriptionProvider? = nil
    ) {
        self.localApiClient = localApiClient
        self.activeWindowCollector = ActiveWindowCollector(localApiClient: localApiClient)
        self.ocrCollector = OCRCollector(localApiClient: localApiClient)
        self.speechTranscriptionProvider = speechTranscriptionProvider ?? AppleSpeechTranscriptionProvider()
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

    var canStartMeetingTranscription: Bool {
        isConnected && !speechTranscriptionProvider.isRunning
    }

    var canStopMeetingTranscription: Bool {
        isConnected && speechTranscriptionProvider.isRunning
    }

    var recordingState: String {
        rawRecordingStatus
    }

    var backendAddressText: String {
        "http://127.0.0.1:8765"
    }

    var dashboardURL: URL {
        URL(string: "\(backendAddressText)/dashboard")!
    }

    func openDashboard() {
        NSWorkspace.shared.open(dashboardURL)
    }

    func startActiveWindowTracking() {
        activeWindowCollector.start(
            isRecordingActive: { [weak self] in
                self?.rawRecordingStatus == "active"
            },
            onStatusChange: { [weak self] status in
                self?.activeWindowTrackingStatus = status
            },
            onSnapshot: { [weak self] snapshot in
                self?.isPrivateAppActive = false
                self?.currentApp = snapshot.appName
                self?.currentWindow = self?.displayValue(snapshot.windowTitle) ?? "없음"
            },
            onPrivateAppChange: { [weak self] isActive in
                self?.isPrivateAppActive = isActive
                if isActive {
                    self?.currentApp = "비공개 앱"
                    self?.currentWindow = "비공개 앱 사용 중"
                }
            }
        )
    }

    func startOCRCollection() {
        ocrCollector.start(
            isRecordingActive: { [weak self] in
                self?.rawRecordingStatus == "active"
            },
            isPrivateAppActive: { [weak self] in
                self?.isPrivateAppActive == true
            },
            currentApp: { [weak self] in
                self?.currentApp ?? "-"
            },
            currentWindow: { [weak self] in
                self?.currentWindow ?? "-"
            },
            onStatusChange: { [weak self] status in
                self?.ocrStatus = status
            }
        )
    }

    func stopActiveWindowTracking() {
        activeWindowCollector.stop()
        ocrCollector.stop()
        activeWindowTrackingStatus = "활성 창 추적 대기 중"
        ocrStatus = "OCR 대기 중"
    }

    func startMeetingTranscription() async {
        guard canStartMeetingTranscription else {
            return
        }

        transcriptionStatus = "권한 확인 중"
        errorMessage = nil

        do {
            try await speechTranscriptionProvider.requestAuthorization()

            let meeting: MeetingResponse
            if let currentMeeting {
                meeting = currentMeeting
            } else {
                meeting = try await localApiClient.startMeeting(title: "음성 전사 회의")
            }
            currentMeeting = meeting
            meetingMode = "켜짐"
            latestTranscriptText = ""
            lastSubmittedTranscriptText = ""
            isStoppingMeetingTranscription = false
            transcriptionStatus = "회의 전사 시작 중"

            try await speechTranscriptionProvider.start(
                localeIdentifier: "ko-KR",
                onTranscript: { [weak self] update in
                    guard let self else {
                        return
                    }
                    await self.handleTranscriptUpdate(update)
                },
                onStatusChange: { [weak self] status in
                    guard let self, !self.isStoppingMeetingTranscription else {
                        return
                    }
                    self.transcriptionStatus = status
                }
            )
        } catch {
            transcriptionStatus = "회의 전사 시작 실패: \(error.localizedDescription)"
            await refreshAfterFailedAction()
        }
    }

    func stopMeetingTranscription() async {
        isStoppingMeetingTranscription = true
        transcriptionStatus = "회의 전사 종료 중"
        let didSaveFinalTranscript = await submitTranscriptIfNeeded(latestTranscriptText)
        await speechTranscriptionProvider.stop()

        do {
            let meeting: MeetingResponse?
            if let currentMeeting {
                meeting = currentMeeting
            } else {
                meeting = try await localApiClient.fetchCurrentMeeting()
            }
            if let meeting {
                try await localApiClient.endMeeting(id: meeting.id)
            }
            currentMeeting = nil
            meetingMode = "꺼짐"
            if didSaveFinalTranscript {
                transcriptionStatus = lastSubmittedTranscriptText.isEmpty ? "회의 전사 종료됨" : "전사 저장 후 종료됨"
            }
            let snapshot = try await localApiClient.fetchSnapshot()
            applySnapshot(snapshot)
        } catch {
            transcriptionStatus = "회의 전사 종료 실패: \(error.localizedDescription)"
            await refreshAfterFailedAction()
        }
        isStoppingMeetingTranscription = false
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

    private func displayRecordingStatus(_ status: String) -> String {
        switch status {
        case "active":
            return "기록중"
        case "paused":
            return "일시정지"
        case "stopped":
            return "정지"
        default:
            return "알 수 없음"
        }
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
        recordingStatus = displayRecordingStatus(snapshot.status.status)
        sessionStartedAt = parseDate(snapshot.status.sessionStartedAt)
        statusElapsedSeconds = snapshot.status.elapsedSeconds
        statusReceivedAt = receivedAt
        recordingElapsedTime = makeElapsedTimeText(at: receivedAt)
        currentMeeting = snapshot.status.currentMeeting
        meetingMode = snapshot.status.meetingMode ? "켜짐" : "꺼짐"
        if isPrivateAppActive {
            currentApp = "비공개 앱"
            currentWindow = "비공개 앱 사용 중"
        } else {
            currentApp = displayValue(snapshot.status.currentApp)
            currentWindow = displayValue(snapshot.status.currentWindow)
        }
    }

    private func handleTranscriptUpdate(_ update: SpeechTranscriptUpdate) async {
        let trimmedText = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return
        }

        latestTranscriptText = trimmedText
        transcriptionStatus = update.isFinal ? "전사 저장 중" : "회의 전사 중"

        if update.isFinal {
            _ = await submitTranscriptIfNeeded(trimmedText)
        }
    }

    private func submitTranscriptIfNeeded(_ text: String) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, trimmedText != lastSubmittedTranscriptText else {
            return true
        }

        do {
            try await localApiClient.createMeetingTranscript(
                meetingSessionId: currentMeeting?.id,
                text: trimmedText
            )
            lastSubmittedTranscriptText = trimmedText
            transcriptionStatus = speechTranscriptionProvider.isRunning ? "전사 저장됨, 회의 전사 중" : "전사 저장됨"
            return true
        } catch {
            transcriptionStatus = "전사 저장 실패: \(error.localizedDescription)"
            return false
        }
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
    @ObservedObject var viewModel: BackendStatusViewModel

    init(viewModel: BackendStatusViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                ConnectionMessageView(isConnected: viewModel.isConnected)

                Spacer()

                Button {
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)

                Button {
                    viewModel.openDashboard()
                } label: {
                    Label("대시보드 열기", systemImage: "safari")
                }
            }

            if !viewModel.isConnected {
                VStack(alignment: .leading, spacing: 4) {
                    Text("로컬 서버가 실행 중인지 확인해 주세요.")
                    Text("주소: \(viewModel.backendAddressText)")
                        .textSelection(.enabled)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Divider()

            RecordingControlsView(viewModel: viewModel)

            StatusSectionView(viewModel: viewModel)

            Divider()

            MeetingTranscriptionSectionView(viewModel: viewModel)

            Divider()

            QuickMemoSectionView(viewModel: viewModel)

            if viewModel.isLoading {
                ProgressView("상태를 확인하는 중")
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 520, minHeight: 500, alignment: .topLeading)
        .padding(24)
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
