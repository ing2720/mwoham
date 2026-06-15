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
        fullMeetingTranscriptionProvider: FullMeetingSpeechTranscriptionProviding
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
    @State private var selectedSection: MainSection? = .today

    init(viewModel: BackendStatusViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Mwoham")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            ScrollView {
                detailContent
                    .frame(maxWidth: 760, alignment: .topLeading)
                    .padding(24)
            }
            .navigationTitle((selectedSection ?? .today).title)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        Task {
                            await viewModel.refresh()
                        }
                    } label: {
                        Label("새로고침", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .task {
            viewModel.startActiveWindowTracking()
            viewModel.startOCRCollection()
            await viewModel.refresh()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            viewModel.updateElapsedTime()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch selectedSection ?? .today {
            case .today:
                TodayView(viewModel: viewModel)
            case .meetingTranscription:
                MeetingTranscriptionPageView(
                    viewModel: viewModel.meetingTranscription
                )
            case .settings:
                SettingsView(viewModel: viewModel)
            }

            if viewModel.isLoading {
                ProgressView("상태를 확인하는 중")
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}

private enum MainSection: String, CaseIterable, Identifiable {
    case today
    case meetingTranscription
    case settings

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .today:
            return "오늘"
        case .meetingTranscription:
            return "회의 전사"
        case .settings:
            return "설정"
        }
    }

    var systemImage: String {
        switch self {
        case .today:
            return "calendar"
        case .meetingTranscription:
            return "waveform"
        case .settings:
            return "gearshape"
        }
    }
}

private struct TodayView: View {
    @ObservedObject var viewModel: BackendStatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ConnectionMessageView(isConnected: viewModel.isConnected)

            GroupBox("기록") {
                VStack(alignment: .leading, spacing: 14) {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 20,
                        verticalSpacing: 10
                    ) {
                        TodayStatusRow(
                            title: "현재 기록 상태",
                            value: viewModel.recordingStatus
                        )
                        TodayStatusRow(
                            title: "기록 시간",
                            value: viewModel.recordingElapsedTime
                        )
                        TodayStatusRow(
                            title: "현재 앱",
                            value: viewModel.currentApp
                        )
                        TodayStatusRow(
                            title: "현재 창",
                            value: viewModel.currentWindow
                        )
                    }

                    RecordingControlsView(viewModel: viewModel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            QuickMemoSectionView(viewModel: viewModel)
        }
    }
}

private struct TodayStatusRow: View {
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

private struct MeetingTranscriptionPageView: View {
    @ObservedObject var viewModel: MeetingTranscriptionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("회의 전사")
                .font(.title2)
                .fontWeight(.semibold)

            MeetingTranscriptionSectionView(viewModel: viewModel)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: BackendStatusViewModel
    @ObservedObject var meetingViewModel: MeetingTranscriptionViewModel

    init(viewModel: BackendStatusViewModel) {
        self.viewModel = viewModel
        self.meetingViewModel = viewModel.meetingTranscription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("설정")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Local Whisper") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Whisper 실행 파일") {
                        TextField(
                            "whisper-cli 절대 경로",
                            text: $meetingViewModel.whisperBinaryPath
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 360)
                    }

                    LabeledContent("Whisper 모델") {
                        TextField(
                            "GGML model 절대 경로",
                            text: $meetingViewModel.whisperModelPath
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 360)
                    }

                    Toggle(
                        "QA/debug용 소스별 WAV 보관",
                        isOn: $meetingViewModel.whisperDebugAudioExportEnabled
                    )

                    Text(
                        "경로와 debug 옵션은 다음 회의 시작부터 적용됩니다. "
                            + "기본 임시 오디오는 처리 후 삭제됩니다."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .disabled(!meetingViewModel.canChangeAudioSource)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Dev Tracking") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(
                        "비워두면 현재 mwoham repo를 추적합니다.",
                        text: $viewModel.devTrackingRepoPath
                    )
                    .textFieldStyle(.roundedBorder)
                    .textSelection(.enabled)

                    LabeledContent("현재 상태") {
                        Text(viewModel.devTrackingStatus)
                            .textSelection(.enabled)
                    }

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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("백엔드") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("연결 상태") {
                        Text(viewModel.isConnected ? "연결됨" : "연결 실패")
                    }
                    LabeledContent("백엔드 주소") {
                        Text(viewModel.backendAddressText)
                            .textSelection(.enabled)
                    }
                    Button {
                        viewModel.openDashboard()
                    } label: {
                        Label("대시보드 열기", systemImage: "safari")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("권한") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("현재 전사 입력") {
                        Text(meetingViewModel.selectedAudioSourceDescription)
                    }

                    LabeledContent("권한 상태") {
                        Text(
                            meetingViewModel.shouldShowSpeechPermissionHelp
                                ? "권한 확인 필요"
                                : "필요 시 시스템 설정에서 확인"
                        )
                    }

                    Text(meetingViewModel.permissionHelpText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack(spacing: 10) {
                        Button {
                            meetingViewModel.openSpeechRecognitionSettings()
                        } label: {
                            Label("음성 인식 설정", systemImage: "waveform")
                        }

                        if meetingViewModel.selectedAudioSource
                            .requiresMicrophone {
                            Button {
                                meetingViewModel.openMicrophoneSettings()
                            } label: {
                                Label("마이크 설정", systemImage: "mic")
                            }
                        }

                        if meetingViewModel.selectedAudioSource
                            .requiresSystemAudio {
                            Button {
                                meetingViewModel.openScreenRecordingSettings()
                            } label: {
                                Label("화면 기록 설정", systemImage: "display")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }
}
