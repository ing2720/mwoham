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
    @Published private(set) var connectionState: ConnectionState = .checking
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshErrorMessage: String?
    @Published private(set) var meetingMode = "-"
    @Published private(set) var currentMeeting: MeetingResponse?
    @Published var meetingTranscription: MeetingTranscriptionViewModel!

    let recording: RecordingViewModel
    let activityTracking: ActivityTrackingViewModel
    let quickMemo: QuickMemoViewModel

    private let localApiClient: LocalApiClient
    private var childSubscriptions: Set<AnyCancellable> = []

    var isLoading: Bool {
        isRefreshing || recording.isLoading
    }

    var errorMessage: String? {
        refreshErrorMessage ?? recording.errorMessage
    }

    var isConnected: Bool {
        connectionState.isActive
    }

    var recordingState: RecordingState {
        recording.state
    }

    var recordingStatus: String {
        recording.state.label
    }

    var recordingElapsedTime: String {
        recording.elapsedTime
    }

    var currentApp: String {
        activityTracking.currentApp
    }

    var currentWindow: String {
        activityTracking.currentWindow
    }

    var activeWindowTrackingState: CollectorState {
        activityTracking.activeWindowState
    }

    var ocrState: CollectorState {
        activityTracking.ocrState
    }

    var devTrackingState: CollectorState {
        activityTracking.devTrackingState
    }

    var shortDevTrackingStatus: String {
        activityTracking.shortDevTrackingLabel
    }

    var isPrivateAppActive: Bool {
        activityTracking.isPrivateAppActive
    }

    var canStartRecording: Bool {
        recording.canStart
    }

    var canPauseRecording: Bool {
        recording.canPause
    }

    var canResumeRecording: Bool {
        recording.canResume
    }

    var canStopRecording: Bool {
        recording.canStop
    }

    var backendAddressText: String {
        "http://127.0.0.1:8765"
    }

    var dashboardURL: URL {
        URL(string: "\(backendAddressText)/dashboard")!
    }

    convenience init() {
        self.init(localApiClient: LocalApiClient())
    }

    init(
        localApiClient: LocalApiClient,
        speechTranscriptionProvider: SpeechTranscriptionProvider? = nil,
        systemAudioTranscriptionProvider: SpeechTranscriptionProvider? = nil
    ) {
        self.localApiClient = localApiClient
        self.recording = RecordingViewModel(localApiClient: localApiClient)
        self.activityTracking = ActivityTrackingViewModel(localApiClient: localApiClient)
        self.quickMemo = QuickMemoViewModel(localApiClient: localApiClient)
        configureMeetingTranscription(
            localApiClient: localApiClient,
            microphoneTranscriptionProvider: speechTranscriptionProvider ?? AppleSpeechTranscriptionProvider(),
            systemAudioTranscriptionProvider: systemAudioTranscriptionProvider ?? SystemAudioSpeechTranscriptionProvider(
                speechPermissionService: SpeechPermissionService()
            ),
            fullMeetingTranscriptionProvider: FullMeetingSpeechTranscriptionProvider()
        )
        configureChildViewModels()
        observeChildViewModels()
    }

    func refresh() async {
        isRefreshing = true
        refreshErrorMessage = nil

        do {
            let snapshot = try await localApiClient.fetchSnapshot()
            applySnapshot(snapshot)
        } catch {
            connectionState = .disconnected
            recording.reset()
            meetingMode = "-"
            activityTracking.resetDisplayedActivity()
            refreshErrorMessage = error.localizedDescription
        }

        isRefreshing = false
    }

    func startRecording() async {
        await recording.start()
    }

    func pauseRecording() async {
        await recording.pause()
    }

    func resumeRecording() async {
        await recording.resume()
    }

    func stopRecording() async {
        await recording.stop()
    }

    func openDashboard() {
        NSWorkspace.shared.open(dashboardURL)
    }

    func startActiveWindowTracking() {
        activityTracking.startActiveWindowTracking()
    }

    func startOCRCollection() {
        activityTracking.startOCRCollection()
    }

    func stopActiveWindowTracking() {
        activityTracking.stopCollectors()
    }

    func updateElapsedTime() {
        recording.updateElapsedTime()
    }

    private func configureChildViewModels() {
        recording.configure(
            isConnected: { [weak self] in
                self?.connectionState.isActive == true
            },
            onSnapshotReceived: { [weak self] snapshot in
                self?.applySnapshot(snapshot)
            },
            onRefreshAfterFailedAction: { [weak self] in
                await self?.refreshAfterFailedAction()
            },
            onSuccessfulAction: { [weak self] transition in
                self?.activityTracking.handleRecordingTransition(transition)
            }
        )
        activityTracking.configure(
            isRecordingActive: { [weak self] in
                self?.recording.state.isActive == true
            },
            isBackendConnected: { [weak self] in
                self?.connectionState.isActive == true
            }
        )
        quickMemo.configure(
            isConnected: { [weak self] in
                self?.connectionState.isActive == true
            },
            onSnapshotReceived: { [weak self] snapshot in
                self?.applySnapshot(snapshot)
            },
            onRefreshAfterFailedAction: { [weak self] in
                await self?.refreshAfterFailedAction()
            }
        )
    }

    private func observeChildViewModels() {
        [recording.objectWillChange, activityTracking.objectWillChange, quickMemo.objectWillChange]
            .forEach { publisher in
                publisher
                    .sink { [weak self] _ in
                        self?.objectWillChange.send()
                    }
                    .store(in: &childSubscriptions)
            }
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
                self?.connectionState.isActive == true
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

    private func refreshAfterFailedAction() async {
        do {
            let snapshot = try await localApiClient.fetchSnapshot()
            applySnapshot(snapshot)
        } catch {
            connectionState = .disconnected
        }
    }

    private func applySnapshot(_ snapshot: BackendSnapshot) {
        let receivedAt = Date()
        connectionState = snapshot.health.status == "ok" ? .connected : .disconnected
        recording.applyStatus(snapshot.status, receivedAt: receivedAt)
        activityTracking.applyStatus(snapshot.status)
        currentMeeting = snapshot.status.currentMeeting
        meetingMode = snapshot.status.meetingMode ? "켜짐" : "꺼짐"
        meetingTranscription.applyStatus(snapshot.status)
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
                ErrorBanner(message: errorMessage)
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
    @ObservedObject var recordingViewModel: RecordingViewModel
    @ObservedObject var activityViewModel: ActivityTrackingViewModel
    @ObservedObject var quickMemoViewModel: QuickMemoViewModel

    init(viewModel: BackendStatusViewModel) {
        self.viewModel = viewModel
        self.recordingViewModel = viewModel.recording
        self.activityViewModel = viewModel.activityTracking
        self.quickMemoViewModel = viewModel.quickMemo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ConnectionMessageView(state: viewModel.connectionState)

            StatusCard("기록", systemImage: "record.circle") {
                VStack(alignment: .leading, spacing: 14) {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 20,
                        verticalSpacing: 10
                    ) {
                        TodayStatusRow(
                            title: "현재 기록 상태",
                            value: recordingViewModel.state.label,
                            status: recordingViewModel.state
                        )
                        TodayStatusRow(
                            title: "기록 시간",
                            value: recordingViewModel.elapsedTime
                        )
                        TodayStatusRow(
                            title: "현재 앱",
                            value: activityViewModel.currentApp
                        )
                        TodayStatusRow(
                            title: "현재 창",
                            value: activityViewModel.currentWindow
                        )
                    }

                    RecordingControl(viewModel: recordingViewModel)
                }
            }

            QuickMemoSectionView(viewModel: quickMemoViewModel)
        }
    }
}

private struct TodayStatusRow: View {
    let title: String
    let value: String
    var status: RecordingState?

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            if let status {
                StatusBadge(state: status, compact: true)
            } else {
                Text(value)
                    .fontWeight(.medium)
                    .textSelection(.enabled)
            }
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
    @ObservedObject var activityViewModel: ActivityTrackingViewModel

    init(viewModel: BackendStatusViewModel) {
        self.viewModel = viewModel
        self.meetingViewModel = viewModel.meetingTranscription
        self.activityViewModel = viewModel.activityTracking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("설정")
                .font(.title2)
                .fontWeight(.semibold)

            StatusCard("Local Whisper", systemImage: "cpu") {
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
            }

            StatusCard("Dev Tracking", systemImage: "point.3.connected.trianglepath.dotted") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(
                        "비워두면 현재 mwoham repo를 추적합니다.",
                        text: $activityViewModel.devTrackingRepoPath
                    )
                    .textFieldStyle(.roundedBorder)
                    .textSelection(.enabled)

                    LabeledContent("현재 상태") {
                        StatusBadge(
                            state: activityViewModel.devTrackingState,
                            compact: true
                        )
                    }

                    Text("추적 repo 경로는 다음 watcher 시작부터 적용됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack {
                        PrimaryActionButton(
                            title: "Dev Tracking 시작",
                            systemImage: "play.circle",
                            isDisabled: activityViewModel.isDevTrackingRunning
                        ) {
                            activityViewModel.startDevTracking()
                        }

                        PrimaryActionButton(
                            title: "Dev Tracking 중지",
                            systemImage: "stop.circle",
                            role: .destructive,
                            isDisabled: !activityViewModel.isDevTrackingRunning
                        ) {
                            activityViewModel.stopDevTracking()
                        }
                    }
                }
            }

            StatusCard("백엔드", systemImage: "server.rack") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("연결 상태") {
                        StatusBadge(
                            state: viewModel.connectionState,
                            compact: true
                        )
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
            }

            StatusCard("권한", systemImage: "lock.shield") {
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
            }
        }
    }
}
