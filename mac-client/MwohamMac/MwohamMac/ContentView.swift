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
    let timeline: TimelineViewModel
    let reports: ReportViewModel
    let backendLifecycle: BackendLifecycleManager

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
        self.backendLifecycle = BackendLifecycleManager(
            localApiClient: localApiClient
        )
        self.recording = RecordingViewModel(localApiClient: localApiClient)
        self.activityTracking = ActivityTrackingViewModel(localApiClient: localApiClient)
        self.quickMemo = QuickMemoViewModel(localApiClient: localApiClient)
        self.timeline = TimelineViewModel(localApiClient: localApiClient)
        self.reports = ReportViewModel(localApiClient: localApiClient)
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

    func prepareBackend() async {
        await backendLifecycle.ensureBackendAvailable()
        await refresh()
    }

    func checkBackendLifecycle() async {
        await backendLifecycle.checkHealth()
        await refresh()
    }

    func startBackend() async {
        await backendLifecycle.startBackend()
        await refresh()
    }

    func restartBackend() async {
        await backendLifecycle.restartBackend()
        await refresh()
    }

    func stopOwnedBackend() {
        backendLifecycle.stopBackend()
        connectionState = .disconnected
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
        [
            recording.objectWillChange,
            activityTracking.objectWillChange,
            quickMemo.objectWillChange,
            timeline.objectWillChange,
            reports.objectWillChange,
            backendLifecycle.objectWillChange,
        ]
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
    @State private var isPermissionOnboardingPresented = false
    @State private var didEvaluatePermissionOnboarding = false
    @AppStorage("hasCompletedPermissionOnboarding")
    private var hasCompletedPermissionOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

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
                            if selectedSection == .timeline {
                                await viewModel.timeline.refresh()
                            } else if selectedSection == .reports {
                                await viewModel.reports.refresh()
                            } else {
                                await viewModel.refresh()
                            }
                        }
                    } label: {
                        Label("새로고침", systemImage: "arrow.clockwise")
                    }
                    .disabled(
                        viewModel.isLoading || viewModel.timeline.isLoading
                            || viewModel.reports.isLoading
                    )
                }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .task {
            viewModel.startActiveWindowTracking()
            viewModel.startOCRCollection()
            await viewModel.prepareBackend()
            presentPermissionOnboardingIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                return
            }
            Task {
                await viewModel.refresh()
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            viewModel.updateElapsedTime()
        }
        .sheet(isPresented: $isPermissionOnboardingPresented) {
            PermissionOnboardingView(
                snapshot: permissionOnboardingSnapshot,
                isRefreshing: viewModel.isLoading,
                refresh: {
                    await viewModel.refresh()
                },
                openMicrophoneSettings: {
                    viewModel.meetingTranscription.openMicrophoneSettings()
                },
                openSpeechRecognitionSettings: {
                    viewModel.meetingTranscription.openSpeechRecognitionSettings()
                },
                openScreenRecordingSettings: {
                    viewModel.meetingTranscription.openScreenRecordingSettings()
                },
                openAccessibilitySettings: openAccessibilitySettings,
                setDebugAudioEnabled: { isEnabled in
                    viewModel.meetingTranscription
                        .whisperDebugAudioExportEnabled = isEnabled
                },
                setDevTrackingEnabled: { isEnabled in
                    viewModel.activityTracking
                        .setDevTrackingEnabled(isEnabled)
                },
                dismiss: {
                    hasCompletedPermissionOnboarding =
                        permissionOnboardingSnapshot.canStart
                    isPermissionOnboardingPresented = false
                }
            )
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch selectedSection ?? .today {
            case .today:
                TodayView(viewModel: viewModel)
            case .timeline:
                TimelinePageView(
                    viewModel: viewModel.timeline,
                    isBackendConnected: viewModel.connectionState.isActive
                )
            case .reports:
                ReportPageView(
                    viewModel: viewModel.reports,
                    isBackendConnected: viewModel.connectionState.isActive
                )
            case .meetingTranscription:
                MeetingTranscriptionPageView(
                    viewModel: viewModel.meetingTranscription
                )
            case .settings:
                SettingsView(
                    viewModel: viewModel,
                    showPermissionOnboarding: {
                        isPermissionOnboardingPresented = true
                    }
                )
            }

            if viewModel.isLoading {
                ProgressView("상태를 확인하는 중")
            }

            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage)
            }
        }
    }

    private var permissionOnboardingSnapshot: PermissionOnboardingSnapshot {
        let inspection = viewModel.meetingTranscription.permissionInspection
        let currentApp = viewModel.activityTracking.currentApp
        let currentWindow = viewModel.activityTracking.currentWindow
        let hasActiveWindowSignal =
            currentApp != "-" && currentApp != "없음"
            && currentWindow != "-" && currentWindow != "없음"

        return PermissionOnboardingSnapshot(
            microphoneAuthorized: inspection.microphoneAuthorized,
            speechRecognitionAuthorized:
                inspection.speechRecognitionAuthorized,
            screenRecordingAuthorized: inspection.screenRecordingAuthorized,
            accessibilityAuthorized: inspection.accessibilityAuthorized,
            localWhisperAvailable:
                viewModel.meetingTranscription.whisperSettingsInspection.state
                    == .localWhisperAvailable,
            backendConnected: viewModel.connectionState.isActive,
            debugAudioEnabled:
                viewModel.meetingTranscription.whisperDebugAudioExportEnabled,
            devTrackingEnabled:
                viewModel.activityTracking.isDevTrackingEnabled,
            hasActiveWindowSignal: hasActiveWindowSignal
        )
    }

    private func presentPermissionOnboardingIfNeeded() {
        guard !didEvaluatePermissionOnboarding else {
            return
        }
        didEvaluatePermissionOnboarding = true
        if !hasCompletedPermissionOnboarding
            || !permissionOnboardingSnapshot.canStart {
            isPermissionOnboardingPresented = true
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private enum MainSection: String, CaseIterable, Identifiable {
    case today
    case timeline
    case reports
    case meetingTranscription
    case settings

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .today:
            return "오늘"
        case .timeline:
            return "타임라인"
        case .reports:
            return "리포트"
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
        case .timeline:
            return "list.bullet.rectangle"
        case .reports:
            return "doc.text"
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
    let showPermissionOnboarding: () -> Void

    init(
        viewModel: BackendStatusViewModel,
        showPermissionOnboarding: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.meetingViewModel = viewModel.meetingTranscription
        self.activityViewModel = viewModel.activityTracking
        self.showPermissionOnboarding = showPermissionOnboarding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("설정")
                .font(.title2)
                .fontWeight(.semibold)

            StatusCard("Local Whisper", systemImage: "cpu") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("사용 상태") {
                        StatusBadge(
                            state: meetingViewModel
                                .whisperSettingsInspection.state,
                            compact: true
                        )
                    }

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

                    LabeledContent("실행 파일 확인") {
                        Text(
                            meetingViewModel.whisperSettingsInspection
                                .binaryIsExecutable
                                ? "실행 가능"
                                : "실행할 수 없음"
                        )
                    }

                    LabeledContent("모델 파일") {
                        Text(
                            meetingViewModel.whisperSettingsInspection.modelExists
                                ? "파일 확인됨"
                                : "파일 없음"
                        )
                    }

                    LabeledContent("모델 크기") {
                        Text(
                            meetingViewModel.whisperSettingsInspection
                                .modelFileSizeText
                        )
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

                    if let message = meetingViewModel
                        .whisperSettingsInspection.state.detail {
                        ErrorBanner(
                            message: message,
                            title: "Local Whisper 설정 확인 필요"
                        )
                    }
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
                    LabeledContent("실행 상태") {
                        StatusBadge(
                            state: viewModel.backendLifecycle.state,
                            compact: true
                        )
                    }
                    LabeledContent("프로세스 소유") {
                        Text(
                            viewModel.backendLifecycle.ownsBackendProcess
                                ? "앱이 시작함"
                                : "외부 실행 또는 없음"
                        )
                    }
                    LabeledContent("백엔드 주소") {
                        Text(viewModel.backendAddressText)
                            .textSelection(.enabled)
                    }

                    HStack {
                        PrimaryActionButton(
                            title: "backend 다시 확인",
                            systemImage: "arrow.clockwise",
                            isDisabled: viewModel.backendLifecycle.isBusy
                        ) {
                            await viewModel.checkBackendLifecycle()
                        }

                        PrimaryActionButton(
                            title: "backend 시작",
                            systemImage: "play.circle",
                            isDisabled:
                                viewModel.backendLifecycle.isBusy
                                || viewModel.backendLifecycle.state == .connected
                        ) {
                            await viewModel.startBackend()
                        }

                        PrimaryActionButton(
                            title: "backend 재시작",
                            systemImage: "arrow.trianglehead.2.clockwise",
                            isDisabled:
                                viewModel.backendLifecycle.isBusy
                                || !viewModel.backendLifecycle
                                    .ownsBackendProcess
                        ) {
                            await viewModel.restartBackend()
                        }
                    }

                    HStack {
                        PrimaryActionButton(
                            title: "앱이 띄운 backend 중지",
                            systemImage: "stop.circle",
                            role: .destructive,
                            isDisabled:
                                !viewModel.backendLifecycle
                                    .ownsBackendProcess
                        ) {
                            viewModel.stopOwnedBackend()
                        }

                        Button {
                            viewModel.openDashboard()
                        } label: {
                            Label("대시보드 열기", systemImage: "safari")
                        }
                    }

                    if let lifecycleError =
                        viewModel.backendLifecycle.lastErrorMessage {
                        ErrorBanner(
                            message: lifecycleError,
                            title: "백엔드 연결 실패"
                        )
                    }

                    DisclosureGroup("backend 진단") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("실행 경로") {
                                Text(
                                    viewModel.backendLifecycle
                                        .backendDirectoryPath
                                )
                                .textSelection(.enabled)
                            }
                            Text(viewModel.backendLifecycle.recentLogText)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                        }
                        .padding(.top, 6)
                    }
                }
            }

            StatusCard("권한", systemImage: "lock.shield") {
                VStack(alignment: .leading, spacing: 10) {
                    PrimaryActionButton(
                        title: "권한 설정 다시 보기",
                        systemImage: "checklist"
                    ) {
                        showPermissionOnboarding()
                    }

                    LabeledContent("현재 전사 입력") {
                        Text(meetingViewModel.selectedAudioSourceDescription)
                    }

                    PermissionStatusRows(
                        meetingViewModel: meetingViewModel,
                        activityViewModel: activityViewModel
                    )

                    Text(meetingViewModel.permissionHelpText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if let permissionErrorMessage =
                        meetingViewModel.permissionErrorMessage {
                        ErrorBanner(
                            message: permissionErrorMessage,
                            title: "STT 권한 확인 필요"
                        )
                    }

                    ForEach(meetingViewModel.permissionIssues) { issue in
                        PermissionBanner(issue: issue)
                    }

                    if let accessibilityIssue =
                        meetingViewModel.permissionInspection.accessibilityIssue {
                        PermissionBanner(issue: accessibilityIssue)
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task {
                                await viewModel.refresh()
                            }
                        } label: {
                            Label("권한 상태 새로고침", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.isLoading)

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

                        if !meetingViewModel.permissionInspection.accessibilityAuthorized {
                            Button {
                                openAccessibilitySettings()
                            } label: {
                                Label("접근성 설정", systemImage: "accessibility")
                            }
                        }
                    }
                }
            }
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct PermissionStatusRows: View {
    @ObservedObject var meetingViewModel: MeetingTranscriptionViewModel
    @ObservedObject var activityViewModel: ActivityTrackingViewModel

    private var inspection: STTPermissionInspection {
        meetingViewModel.permissionInspection
    }

    private var hasActiveWindowSignal: Bool {
        activityViewModel.currentApp != "-"
            && activityViewModel.currentApp != "없음"
            && activityViewModel.currentWindow != "-"
            && activityViewModel.currentWindow != "없음"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("활성 창 추적") {
                StatusBadge(
                    state: hasActiveWindowSignal
                        ? CollectorState.running("활성 창 추적 중")
                        : activityViewModel.activeWindowState,
                    compact: true
                )
            }
            LabeledContent("음성 인식") {
                Text(inspection.speechRecognitionAuthorized ? "허용됨" : "권한 확인 필요")
            }
            LabeledContent("마이크") {
                Text(inspection.microphoneAuthorized ? "허용됨" : "권한 확인 필요")
            }
            LabeledContent("화면 기록") {
                Text(inspection.screenRecordingAuthorized ? "허용됨" : "권한 확인 필요")
            }
            LabeledContent("접근성") {
                Text(inspection.accessibilityAuthorized ? "허용됨" : "권한 확인 필요")
            }
        }
    }
}

private struct PermissionBanner: View {
    let issue: PermissionIssue

    var body: some View {
        if issue.isWarning {
            WarningBanner(message: issue.message, title: issue.title)
        } else {
            ErrorBanner(message: issue.message, title: issue.title)
        }
    }
}
