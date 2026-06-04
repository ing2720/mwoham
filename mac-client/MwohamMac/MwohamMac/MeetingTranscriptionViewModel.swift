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

    private let localApiClient: LocalApiClient
    private let speechTranscriptionProvider: SpeechTranscriptionProvider
    private let speechPermissionService: SpeechPermissionServicing
    private let transcriptSubmissionPolicy: MeetingTranscriptSubmissionPolicy
    private let isConnected: () -> Bool
    private let onMeetingStateChange: (MeetingResponse?, String) -> Void
    private let onRefreshAfterFailedAction: () async -> Void
    private let onSnapshotReceived: (BackendSnapshot) -> Void
    private var lastSubmittedTranscriptText = ""
    private var lastTranscriptSubmissionAt: Date?
    private var isMeetingTranscribing = false
    private var isStoppingMeetingTranscription = false

    init(
        localApiClient: LocalApiClient,
        speechTranscriptionProvider: SpeechTranscriptionProvider,
        speechPermissionService: SpeechPermissionServicing,
        transcriptSubmissionPolicy: MeetingTranscriptSubmissionPolicy,
        isConnected: @escaping () -> Bool,
        onMeetingStateChange: @escaping (MeetingResponse?, String) -> Void,
        onRefreshAfterFailedAction: @escaping () async -> Void,
        onSnapshotReceived: @escaping (BackendSnapshot) -> Void
    ) {
        self.localApiClient = localApiClient
        self.speechTranscriptionProvider = speechTranscriptionProvider
        self.speechPermissionService = speechPermissionService
        self.transcriptSubmissionPolicy = transcriptSubmissionPolicy
        self.isConnected = isConnected
        self.onMeetingStateChange = onMeetingStateChange
        self.onRefreshAfterFailedAction = onRefreshAfterFailedAction
        self.onSnapshotReceived = onSnapshotReceived
    }

    var canStart: Bool {
        isConnected() && !speechTranscriptionProvider.isRunning
    }

    var canStop: Bool {
        isConnected() && speechTranscriptionProvider.isRunning
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
            try await speechPermissionService.requestAuthorization()

            let meeting: MeetingResponse
            if let currentMeeting {
                meeting = currentMeeting
            } else {
                meeting = try await localApiClient.startMeeting(title: "음성 전사 회의")
            }
            currentMeeting = meeting
            meetingMode = "켜짐"
            onMeetingStateChange(meeting, meetingMode)
            latestTranscriptText = ""
            lastSubmittedTranscriptText = ""
            lastTranscriptSubmissionAt = nil
            isMeetingTranscribing = true
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
            isMeetingTranscribing = false
            isStoppingMeetingTranscription = false
            shouldShowSpeechPermissionHelp = speechPermissionService.isPermissionError(error)
            transcriptionStatus = "회의 전사 시작 실패: \(error.localizedDescription)"
            await onRefreshAfterFailedAction()
        }
    }

    func stop() async {
        guard isMeetingTranscribing || speechTranscriptionProvider.isRunning else {
            return
        }

        isMeetingTranscribing = false
        isStoppingMeetingTranscription = true
        transcriptionStatus = "회의 전사 종료 중"
        let didSaveFinalTranscript = await submitTranscriptIfNeeded(
            latestTranscriptText,
            allowsRunningStatusUpdate: false,
            force: true
        )
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
            onMeetingStateChange(nil, meetingMode)
            if didSaveFinalTranscript {
                transcriptionStatus = lastSubmittedTranscriptText.isEmpty ? "회의 전사 종료됨" : "전사 저장 후 종료됨"
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

    func showPermissionAlert() {
        speechPermissionService.showPermissionAlert()
    }

    private func handleTranscriptUpdate(_ update: SpeechTranscriptUpdate) async {
        let trimmedText = transcriptSubmissionPolicy.normalize(update.text)
        guard !trimmedText.isEmpty else {
            return
        }

        latestTranscriptText = trimmedText
        let canUpdateRunningStatus = isMeetingTranscribing && !isStoppingMeetingTranscription
        if canUpdateRunningStatus {
            transcriptionStatus = update.isFinal ? "전사 저장 중" : "회의 전사 중"
        }

        if update.isFinal {
            _ = await submitTranscriptIfNeeded(
                trimmedText,
                allowsRunningStatusUpdate: canUpdateRunningStatus
            )
        }
    }

    private func submitTranscriptIfNeeded(
        _ text: String,
        allowsRunningStatusUpdate: Bool = true,
        force: Bool = false
    ) async -> Bool {
        let trimmedText = transcriptSubmissionPolicy.normalize(text)
        if transcriptSubmissionPolicy.shouldSkipSubmission(
            text: trimmedText,
            lastSubmittedText: lastSubmittedTranscriptText,
            lastSubmittedAt: lastTranscriptSubmissionAt,
            force: force
        ) {
            return true
        }

        do {
            try await localApiClient.createMeetingTranscript(
                meetingSessionId: currentMeeting?.id,
                text: trimmedText
            )
            lastSubmittedTranscriptText = trimmedText
            lastTranscriptSubmissionAt = Date()
            if allowsRunningStatusUpdate && isMeetingTranscribing && !isStoppingMeetingTranscription {
                transcriptionStatus = "전사 저장됨, 회의 전사 중"
            } else if allowsRunningStatusUpdate {
                transcriptionStatus = "전사 저장됨"
            }
            return true
        } catch {
            transcriptionStatus = "전사 저장 실패: \(error.localizedDescription)"
            return false
        }
    }
}
