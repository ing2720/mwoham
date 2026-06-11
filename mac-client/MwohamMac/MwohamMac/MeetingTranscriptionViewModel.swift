//
//  MeetingTranscriptionViewModel.swift
//  MwohamMac
//

import Combine
import Foundation

@MainActor
final class MeetingTranscriptionViewModel: ObservableObject {
    @Published var currentMeeting: MeetingResponse?
    @Published var meetingMode = "-"
    @Published var transcriptionStatus = "회의 전사 대기 중"
    @Published var latestTranscriptText = ""
    @Published var shouldShowSpeechPermissionHelp = false
    @Published var selectedAudioSource: MeetingAudioSource = .microphone
    @Published var microphoneProviderStatus = "마이크 대기 중"
    @Published var systemAudioProviderStatus = "시스템 오디오 대기 중"
    @Published var fullMeetingProviderStatus = "회의 전체 대기 중"

    private let localApiClient: LocalApiClient
    private let microphoneTranscriptionProvider: SpeechTranscriptionProvider
    private let systemAudioTranscriptionProvider: SpeechTranscriptionProvider
    private let fullMeetingTranscriptionProvider: SpeechTranscriptionProvider
    private let speechPermissionService: SpeechPermissionServicing
    private let transcriptSubmissionPolicy: MeetingTranscriptSubmissionPolicy
    private let isConnected: () -> Bool
    private let onMeetingStateChange: (MeetingResponse?, String) -> Void
    private let onRefreshAfterFailedAction: () async -> Void
    private let onSnapshotReceived: (BackendSnapshot) -> Void
    private var latestTranscriptTextBySource: [String: String] = [:]
    private var lastSubmittedTranscriptTextBySource: [String: String] = [:]
    private var lastTranscriptSubmissionAtBySource: [String: Date] = [:]
    private var isMeetingTranscribing = false
    private var isStoppingMeetingTranscription = false
    private var activeAudioSource: MeetingAudioSource = .microphone
    private var providerFailureMessages: [String] = []

    init(
        localApiClient: LocalApiClient,
        microphoneTranscriptionProvider: SpeechTranscriptionProvider,
        systemAudioTranscriptionProvider: SpeechTranscriptionProvider,
        fullMeetingTranscriptionProvider: SpeechTranscriptionProvider,
        speechPermissionService: SpeechPermissionServicing,
        transcriptSubmissionPolicy: MeetingTranscriptSubmissionPolicy,
        isConnected: @escaping () -> Bool,
        onMeetingStateChange: @escaping (MeetingResponse?, String) -> Void,
        onRefreshAfterFailedAction: @escaping () async -> Void,
        onSnapshotReceived: @escaping (BackendSnapshot) -> Void
    ) {
        self.localApiClient = localApiClient
        self.microphoneTranscriptionProvider = microphoneTranscriptionProvider
        self.systemAudioTranscriptionProvider = systemAudioTranscriptionProvider
        self.fullMeetingTranscriptionProvider = fullMeetingTranscriptionProvider
        self.speechPermissionService = speechPermissionService
        self.transcriptSubmissionPolicy = transcriptSubmissionPolicy
        self.isConnected = isConnected
        self.onMeetingStateChange = onMeetingStateChange
        self.onRefreshAfterFailedAction = onRefreshAfterFailedAction
        self.onSnapshotReceived = onSnapshotReceived
    }

    var canStart: Bool {
        isConnected() && !isAnyProviderRunning
    }

    var canStop: Bool {
        isConnected() && isAnyProviderRunning
    }

    var canChangeAudioSource: Bool {
        !isAnyProviderRunning && !isMeetingTranscribing
    }

    var selectedAudioSourceDescription: String {
        selectedAudioSource.displayName
    }

    var permissionHelpText: String {
        selectedAudioSource.permissionHelpText
    }

    var selectedAudioSourceGuidanceText: String? {
        selectedAudioSource.guidanceText
    }

    func applyStatus(_ status: StatusResponse) {
        currentMeeting = status.currentMeeting
        meetingMode = status.meetingMode ? "켜짐" : "꺼짐"
        onMeetingStateChange(currentMeeting, meetingMode)
    }

    func start() async {
        if shouldShowSpeechPermissionHelp {
            showPermissionAlert()
            return
        }

        guard canStart else {
            return
        }

        transcriptionStatus = "권한 확인 중"
        shouldShowSpeechPermissionHelp = false

        do {
            try await requestAuthorization(for: selectedAudioSource)

            let meeting: MeetingResponse
            if let currentMeeting {
                meeting = currentMeeting
            } else {
                try await ensureActiveRecordingSession()
                meeting = try await localApiClient.startMeeting(title: "음성 전사 회의")
            }
            currentMeeting = meeting
            meetingMode = "켜짐"
            onMeetingStateChange(meeting, meetingMode)
            latestTranscriptText = ""
            latestTranscriptTextBySource = [:]
            lastSubmittedTranscriptTextBySource = [:]
            lastTranscriptSubmissionAtBySource = [:]
            providerFailureMessages = []
            resetProviderStatuses()
            activeAudioSource = selectedAudioSource
            isMeetingTranscribing = true
            isStoppingMeetingTranscription = false
            transcriptionStatus = activeAudioSource.startStatusText

            let providerErrors = await startProviders(for: activeAudioSource)
            if !isAnyProviderRunning {
                throw providerErrors.first ?? SpeechTranscriptionError.recognizerUnavailable
            }
            if providerErrors.isEmpty {
                transcriptionStatus = activeAudioSource == .fullMeeting ? "회의 전체 전사 중" : "회의 전사 중"
            } else {
                shouldShowSpeechPermissionHelp = providerErrors.contains { speechPermissionService.isPermissionError($0) }
                transcriptionStatus = fullMeetingStatusSummary()
            }
        } catch {
            isMeetingTranscribing = false
            isStoppingMeetingTranscription = false
            await microphoneTranscriptionProvider.stop()
            await systemAudioTranscriptionProvider.stop()
            await fullMeetingTranscriptionProvider.stop()
            shouldShowSpeechPermissionHelp = speechPermissionService.isPermissionError(error)
            transcriptionStatus = "회의 전사 시작 실패: \(error.localizedDescription)"
            await onRefreshAfterFailedAction()
        }
    }

    func stop() async {
        guard isMeetingTranscribing || isAnyProviderRunning else {
            return
        }

        isMeetingTranscribing = false
        isStoppingMeetingTranscription = true
        transcriptionStatus = "회의 전사 종료 중"
        let didSaveFinalTranscript = await submitFinalTranscriptsIfNeeded(
            allowsRunningStatusUpdate: false,
            force: true
        )
        await microphoneTranscriptionProvider.stop()
        await systemAudioTranscriptionProvider.stop()
        await fullMeetingTranscriptionProvider.stop()

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
            onMeetingStateChange(nil, meetingMode)
            if didSaveFinalTranscript {
                if lastSubmittedTranscriptTextBySource.isEmpty {
                    transcriptionStatus = activeAudioSource == .fullMeeting ? "회의 전체 전사 종료됨" : "회의 전사 종료됨"
                } else {
                    transcriptionStatus = "전사 저장 후 종료됨"
                }
            }
            let snapshot = try await localApiClient.fetchSnapshot()
            onSnapshotReceived(snapshot)
        } catch {
            transcriptionStatus = "회의 전사 종료 실패: \(error.localizedDescription)"
            await onRefreshAfterFailedAction()
        }
        isStoppingMeetingTranscription = false
    }

    func openSpeechRecognitionSettings() {
        speechPermissionService.openSpeechRecognitionSettings()
    }

    func openMicrophoneSettings() {
        speechPermissionService.openMicrophoneSettings()
    }

    func openScreenRecordingSettings() {
        speechPermissionService.openScreenRecordingSettings()
    }

    func showPermissionAlert() {
        speechPermissionService.showPermissionAlert()
    }

    private func handleTranscriptUpdate(_ update: SpeechTranscriptUpdate, transcriptSource: String) async {
        let trimmedText = transcriptSubmissionPolicy.normalize(update.text)
        guard !trimmedText.isEmpty else {
            return
        }

        latestTranscriptText = trimmedText
        latestTranscriptTextBySource[transcriptSource] = trimmedText
        updateProviderStatus(
            transcriptSource,
            status: update.isFinal ? "\(providerLabel(for: transcriptSource)) 최종 전사 수신됨" : "\(providerLabel(for: transcriptSource)) 전사 중"
        )
        let canUpdateRunningStatus = isMeetingTranscribing && !isStoppingMeetingTranscription
        if canUpdateRunningStatus {
            if update.isFinal {
                transcriptionStatus = "전사 저장 중"
            } else if activeAudioSource == .fullMeeting {
                transcriptionStatus = fullMeetingStatusSummary()
            } else {
                transcriptionStatus = "회의 전사 중"
            }
        }

        if update.isFinal {
            _ = await submitTranscriptIfNeeded(
                trimmedText,
                transcriptSource: transcriptSource,
                allowsRunningStatusUpdate: canUpdateRunningStatus
            )
        }
    }

    private func submitTranscriptIfNeeded(
        _ text: String,
        transcriptSource: String,
        allowsRunningStatusUpdate: Bool = true,
        force: Bool = false
    ) async -> Bool {
        let trimmedText = transcriptSubmissionPolicy.normalize(text)
        if transcriptSubmissionPolicy.shouldSkipSubmission(
            text: trimmedText,
            lastSubmittedText: lastSubmittedTranscriptTextBySource[transcriptSource] ?? "",
            lastSubmittedAt: lastTranscriptSubmissionAtBySource[transcriptSource],
            force: force
        ) {
            return true
        }

        do {
            try await localApiClient.createMeetingTranscript(
                meetingSessionId: currentMeeting?.id,
                text: trimmedText,
                source: transcriptSource
            )
            lastSubmittedTranscriptTextBySource[transcriptSource] = trimmedText
            lastTranscriptSubmissionAtBySource[transcriptSource] = Date()
            updateProviderStatus(
                transcriptSource,
                status: "\(providerLabel(for: transcriptSource)) 전사 저장됨"
            )
            if allowsRunningStatusUpdate && isMeetingTranscribing && !isStoppingMeetingTranscription {
                transcriptionStatus = activeAudioSource == .fullMeeting ? fullMeetingStatusSummary() : "전사 저장됨, 회의 전사 중"
            } else if allowsRunningStatusUpdate {
                transcriptionStatus = "전사 저장됨"
            }
            return true
        } catch {
            let message = "\(providerLabel(for: transcriptSource)) 전사 저장 실패: \(error.localizedDescription)"
            updateProviderStatus(transcriptSource, status: message)
            transcriptionStatus = activeAudioSource == .fullMeeting ? fullMeetingStatusSummary() : message
            return false
        }
    }

    private func submitFinalTranscriptsIfNeeded(
        allowsRunningStatusUpdate: Bool,
        force: Bool
    ) async -> Bool {
        let submissions = latestTranscriptTextBySource
        guard !submissions.isEmpty else {
            return true
        }

        var didSaveAll = true
        for (source, text) in submissions {
            let didSave = await submitTranscriptIfNeeded(
                text,
                transcriptSource: source,
                allowsRunningStatusUpdate: allowsRunningStatusUpdate,
                force: force
            )
            didSaveAll = didSaveAll && didSave
        }
        return didSaveAll
    }

    private func startProviders(for audioSource: MeetingAudioSource) async -> [Error] {
        var errors: [Error] = []

        if audioSource == .fullMeeting {
            if let error = await startProviderIfNeeded(
                transcriptSource: MeetingAudioSource.fullMeeting.primaryTranscriptSource
            ) {
                errors.append(error)
            }
            return errors
        }

        if audioSource.requiresMicrophone,
           let error = await startProviderIfNeeded(
               transcriptSource: MeetingAudioSource.microphone.primaryTranscriptSource
           ) {
            errors.append(error)
        }

        if audioSource.requiresSystemAudio,
           let error = await startProviderIfNeeded(
               transcriptSource: MeetingAudioSource.systemAudio.primaryTranscriptSource
           ) {
            errors.append(error)
        }

        return errors
    }

    private func startProviderIfNeeded(transcriptSource: String) async -> Error? {
        do {
            updateProviderStatus(
                transcriptSource,
                status: "\(providerLabel(for: transcriptSource)) 시작 중"
            )
            try await startProvider(
                provider(for: transcriptSource),
                transcriptSource: transcriptSource
            )
            updateProviderStatus(
                transcriptSource,
                status: "\(providerLabel(for: transcriptSource)) 시작 완료, 전사 대기 중"
            )
            if activeAudioSource == .fullMeeting {
                transcriptionStatus = fullMeetingStatusSummary()
            }
            return nil
        } catch {
            recordProviderFailure(
                transcriptSource: transcriptSource,
                reason: SpeechRecognitionErrorFormatter.describe(error)
            )
            return error
        }
    }

    private func startProvider(
        _ provider: SpeechTranscriptionProvider,
        transcriptSource: String
    ) async throws {
        try await provider.start(
            localeIdentifier: "ko-KR",
            onTranscript: { [weak self] update in
                guard let self else {
                    return
                }
                await self.handleTranscriptUpdate(update, transcriptSource: transcriptSource)
            },
            onStatusChange: { [weak self] status in
                guard let self, !self.isStoppingMeetingTranscription else {
                    return
                }
                self.handleProviderStatus(status, transcriptSource: transcriptSource)
            }
        )
    }

    private func ensureActiveRecordingSession() async throws {
        let snapshot = try await localApiClient.fetchSnapshot()
        onSnapshotReceived(snapshot)

        switch snapshot.status.status {
        case "active":
            return
        case "paused":
            try await localApiClient.resumeRecording()
        default:
            try await localApiClient.startRecording()
        }

        let refreshedSnapshot = try await localApiClient.fetchSnapshot()
        onSnapshotReceived(refreshedSnapshot)
    }

    private func handleProviderStatus(_ status: String, transcriptSource: String) {
        guard isMeetingTranscribing else {
            transcriptionStatus = status
            return
        }

        if status.contains("오류") || status.contains("실패") {
            recordProviderFailure(transcriptSource: transcriptSource, reason: status)
            transcriptionStatus = activeAudioSource == .fullMeeting ? fullMeetingStatusSummary() : status
            return
        }

        updateProviderStatus(transcriptSource, status: statusForDisplay(status, transcriptSource: transcriptSource))

        if activeAudioSource == .fullMeeting {
            transcriptionStatus = fullMeetingStatusSummary()
        } else {
            transcriptionStatus = status
        }
    }

    private func resetProviderStatuses() {
        microphoneProviderStatus = selectedAudioSource.requiresMicrophone ? "마이크 대기 중" : "마이크 사용 안 함"
        systemAudioProviderStatus = selectedAudioSource.requiresSystemAudio ? "시스템 오디오 대기 중" : "시스템 오디오 사용 안 함"
        fullMeetingProviderStatus = selectedAudioSource == .fullMeeting ? "회의 전체 대기 중" : "회의 전체 사용 안 함"
    }

    private func updateProviderStatus(_ transcriptSource: String, status: String) {
        if transcriptSource == MeetingAudioSource.fullMeeting.primaryTranscriptSource {
            fullMeetingProviderStatus = status
        } else if transcriptSource == MeetingAudioSource.systemAudio.primaryTranscriptSource {
            systemAudioProviderStatus = status
        } else {
            microphoneProviderStatus = status
        }
    }

    private func recordProviderFailure(transcriptSource: String, reason: String) {
        let label = providerLabel(for: transcriptSource)
        let message = "\(label) 입력 실패: \(reason)"
        updateProviderStatus(transcriptSource, status: message)
        if !providerFailureMessages.contains(message) {
            providerFailureMessages.append(message)
        }
    }

    private func fullMeetingStatusSummary() -> String {
        if providerFailureMessages.isEmpty {
            return "회의 전체 전사 중, \(fullMeetingProviderStatus)"
        }
        return "회의 전체 전사 중, \(providerFailureMessages.joined(separator: " / "))"
    }

    private func statusForDisplay(_ status: String, transcriptSource: String) -> String {
        let label = providerLabel(for: transcriptSource)
        if status.contains(label) {
            return status
        }
        return "\(label): \(status)"
    }

    private func providerLabel(for transcriptSource: String) -> String {
        if transcriptSource == MeetingAudioSource.fullMeeting.primaryTranscriptSource {
            return "회의 전체"
        }
        return transcriptSource == MeetingAudioSource.systemAudio.primaryTranscriptSource ? "시스템 오디오" : "마이크"
    }

    private func provider(for transcriptSource: String) -> SpeechTranscriptionProvider {
        if transcriptSource == MeetingAudioSource.fullMeeting.primaryTranscriptSource {
            return fullMeetingTranscriptionProvider
        }
        return transcriptSource == MeetingAudioSource.systemAudio.primaryTranscriptSource
            ? systemAudioTranscriptionProvider
            : microphoneTranscriptionProvider
    }

    private var isAnyProviderRunning: Bool {
        microphoneTranscriptionProvider.isRunning
            || systemAudioTranscriptionProvider.isRunning
            || fullMeetingTranscriptionProvider.isRunning
    }

    private func requestAuthorization(for audioSource: MeetingAudioSource) async throws {
        switch audioSource {
        case .microphone:
            try await speechPermissionService.requestAuthorization()
        case .systemAudio:
            try await speechPermissionService.requestSpeechRecognitionAuthorization()
        case .fullMeeting:
            try await speechPermissionService.requestAuthorization()
        }
    }
}
