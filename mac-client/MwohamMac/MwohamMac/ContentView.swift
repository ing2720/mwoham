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
    @Published var devTrackingStatus = "Dev Tracking: 대기 중"
    @Published var devTrackingRepoPath: String {
        didSet {
            UserDefaults.standard.set(devTrackingRepoPath, forKey: Self.devTrackingRepoPathKey)
        }
    }
    @Published var devTrackingManualStartRequested = false
    @Published var currentMeeting: MeetingResponse?
    @Published var meetingTranscription: MeetingTranscriptionViewModel!

    private static let devTrackingRepoPathKey = "devTrackingRepoPath"
    private let localApiClient: LocalApiClient
    private let activeWindowCollector: ActiveWindowCollector
    private let ocrCollector: OCRCollector
    private let devTrackingProcessController: DevTrackingProcessController
    private var rawRecordingStatus = "unknown"
    private var sessionStartedAt: Date?
    private var statusElapsedSeconds: Int?
    private var statusReceivedAt: Date?

    var shortDevTrackingStatus: String {
        if devTrackingStatus.contains("오류") {
            return "오류"
        }

        if devTrackingStatus.contains("감시 중")
            || devTrackingStatus.contains("감시 시작")
            || devTrackingStatus.contains("변경 없음")
            || devTrackingStatus.contains("변경 감지")
            || devTrackingStatus.contains("DevEvent 저장됨") {
            return "Dev 추적 중"
        }

        return "대기"
    }

    init() {
        let localApiClient = LocalApiClient()
        self.devTrackingRepoPath = UserDefaults.standard.string(forKey: Self.devTrackingRepoPathKey) ?? ""
        self.localApiClient = localApiClient
        self.activeWindowCollector = ActiveWindowCollector(localApiClient: localApiClient)
        self.ocrCollector = OCRCollector(localApiClient: localApiClient)
        self.devTrackingProcessController = DevTrackingProcessController(
            repoPathProvider: {
                UserDefaults.standard.string(forKey: BackendStatusViewModel.devTrackingRepoPathKey) ?? ""
            }
        )
        configureMeetingTranscription(
            localApiClient: localApiClient,
            microphoneTranscriptionProvider: AppleSpeechTranscriptionProvider(),
            systemAudioTranscriptionProvider: SystemAudioSpeechTranscriptionProvider(
                speechPermissionService: SpeechPermissionService()
            ),
            fullMeetingTranscriptionProvider: FullMeetingSpeechTranscriptionProvider()
        )
    }

    init(
        localApiClient: LocalApiClient,
        speechTranscriptionProvider: SpeechTranscriptionProvider? = nil,
        systemAudioTranscriptionProvider: SpeechTranscriptionProvider? = nil
    ) {
        self.devTrackingRepoPath = UserDefaults.standard.string(forKey: Self.devTrackingRepoPathKey) ?? ""
        self.localApiClient = localApiClient
        self.activeWindowCollector = ActiveWindowCollector(localApiClient: localApiClient)
        self.ocrCollector = OCRCollector(localApiClient: localApiClient)
        self.devTrackingProcessController = DevTrackingProcessController(
            repoPathProvider: {
                UserDefaults.standard.string(forKey: BackendStatusViewModel.devTrackingRepoPathKey) ?? ""
            }
        )
        configureMeetingTranscription(
            localApiClient: localApiClient,
            microphoneTranscriptionProvider: speechTranscriptionProvider ?? AppleSpeechTranscriptionProvider(),
            systemAudioTranscriptionProvider: systemAudioTranscriptionProvider ?? SystemAudioSpeechTranscriptionProvider(
                speechPermissionService: SpeechPermissionService()
            ),
            fullMeetingTranscriptionProvider: FullMeetingSpeechTranscriptionProvider()
        )
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

    private func configureMeetingTranscription(
        localApiClient: LocalApiClient,
        microphoneTranscriptionProvider: SpeechTranscriptionProvider,
        systemAudioTranscriptionProvider: SpeechTranscriptionProvider,
        fullMeetingTranscriptionProvider: SpeechTranscriptionProvider
    ) {
        meetingTranscription = MeetingTranscriptionViewModel(
            localApiClient: localApiClient,
            microphoneTranscriptionProvider: microphoneTranscriptionProvider,
            systemAudioTranscriptionProvider: systemAudioTranscriptionProvider,
            fullMeetingTranscriptionProvider: fullMeetingTranscriptionProvider,
            speechPermissionService: SpeechPermissionService(),
            transcriptSubmissionPolicy: MeetingTranscriptSubmissionPolicy(),
            isConnected: { [weak self] in
                self?.isConnected == true
            },
            onMeetingStateChange: { [weak self] meeting, meetingMode in
                self?.currentMeeting = meeting
                self?.meetingMode = meetingMode
            },
            onRefreshAfterFailedAction: { [weak self] in
                await self?.refreshAfterFailedAction()
            },
            onSnapshotReceived: { [weak self] snapshot in
                self?.applySnapshot(snapshot)
            }
        )
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
            },
            onFrontmostAppChange: { [weak self] appName in
                guard let self, self.devTrackingManualStartRequested else {
                    self?.devTrackingStatus = "Dev Tracking: 수동 시작 대기 중"
                    return
                }
                self.devTrackingProcessController.handleActiveApplication(appName) { status in
                    self.devTrackingStatus = status
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
        devTrackingManualStartRequested = false
        devTrackingProcessController.stop { [weak self] status in
            self?.devTrackingStatus = status
        }
        activeWindowTrackingStatus = "활성 창 추적 대기 중"
        ocrStatus = "OCR 대기 중"
    }

    func startDevTracking() {
        devTrackingManualStartRequested = true
        if devTrackingRepoPathForDisplay().contains("/Desktop/") {
            devTrackingStatus = "Dev Tracking: Desktop repo 접근 권한이 필요할 수 있음"
        }
        devTrackingProcessController.handleActiveApplication(currentApp) { [weak self] status in
            self?.devTrackingStatus = status
        }
    }

    func stopDevTracking() {
        devTrackingManualStartRequested = false
        devTrackingProcessController.stop { [weak self] status in
            self?.devTrackingStatus = status
        }
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

    private func devTrackingRepoPathForDisplay() -> String {
        let configuredPath = devTrackingRepoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuredPath.isEmpty {
            return DevTrackingProcessController.defaultRepoPathForDisplay()
        }
        return configuredPath
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
        meetingTranscription.applyStatus(snapshot.status)
        if isPrivateAppActive {
            currentApp = "비공개 앱"
            currentWindow = "비공개 앱 사용 중"
        } else {
            currentApp = displayValue(snapshot.status.currentApp)
            currentWindow = displayValue(snapshot.status.currentWindow)
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

            DevTrackingSettingsView(viewModel: viewModel)

            Divider()

            MeetingTranscriptionSectionView(viewModel: viewModel.meetingTranscription)

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

private struct DevTrackingSettingsView: View {
    @ObservedObject var viewModel: BackendStatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dev Tracking 설정")
                .font(.headline)

            TextField("비워두면 현재 mwoham repo를 추적합니다.", text: $viewModel.devTrackingRepoPath)
                .textFieldStyle(.roundedBorder)
                .textSelection(.enabled)

            Text("추적 repo 경로는 다음 watcher 시작부터 적용됩니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Dev Tracking 시작") {
                    viewModel.startDevTracking()
                }
                .disabled(viewModel.devTrackingManualStartRequested)

                Button("Dev Tracking 중지") {
                    viewModel.stopDevTracking()
                }
                .disabled(!viewModel.devTrackingManualStartRequested)
            }
        }
    }
}
