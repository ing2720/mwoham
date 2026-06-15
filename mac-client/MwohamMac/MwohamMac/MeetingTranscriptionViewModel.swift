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
    @Published var currentSTTEngine = "Apple Speech"
    @Published var whisperDiagnostics = "아직 처리된 Whisper 오디오가 없습니다."
    @Published var whisperInputSources =
        "microphone/system audio Whisper chunks -> time-ordered full meeting"
    @Published var whisperBinaryPath: String {
        didSet {
            UserDefaults.standard.set(
                whisperBinaryPath,
                forKey: LocalWhisperSettings.binaryPathKey
            )
        }
    }
    @Published var whisperModelPath: String {
        didSet {
            UserDefaults.standard.set(
                whisperModelPath,
                forKey: LocalWhisperSettings.modelPathKey
            )
        }
    }
    @Published var whisperDebugAudioExportEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                whisperDebugAudioExportEnabled,
                forKey: LocalWhisperSettings.debugAudioExportEnabledKey
            )
        }
    }

    private let localApiClient: LocalApiClient
    private let microphoneTranscriptionProvider: SpeechTranscriptionProvider
    private let systemAudioTranscriptionProvider: SpeechTranscriptionProvider
    private let fullMeetingTranscriptionProvider: FullMeetingSpeechTranscriptionProviding
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
        fullMeetingTranscriptionProvider: FullMeetingSpeechTranscriptionProviding,
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
        self.whisperBinaryPath = UserDefaults.standard.string(
            forKey: LocalWhisperSettings.binaryPathKey
        ) ?? ""
        self.whisperModelPath = UserDefaults.standard.string(
            forKey: LocalWhisperSettings.modelPathKey
        ) ?? ""
        self.whisperDebugAudioExportEnabled = UserDefaults.standard.bool(
            forKey: LocalWhisperSettings.debugAudioExportEnabledKey
        )
        self.isConnected = isConnected
        self.onMeetingStateChange = onMeetingStateChange
        self.onRefreshAfterFailedAction = onRefreshAfterFailedAction
        self.onSnapshotReceived = onSnapshotReceived
    }

    var canStart: Bool {
        isConnected()
            && !isAnyProviderRunning
            && !isMeetingTranscribing
            && !isStoppingMeetingTranscription
    }

    var canStop: Bool {
        isConnected() && isAnyProviderRunning
    }

    var canChangeAudioSource: Bool {
        !isAnyProviderRunning
            && !isMeetingTranscribing
            && !isStoppingMeetingTranscription
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

    var displayedSTTEngine: String {
        if isMeetingTranscribing || isStoppingMeetingTranscription {
            return currentSTTEngine
        }
        return selectedAudioSource == .fullMeeting
            ? fullMeetingTranscriptionProvider.preferredEngineDescription
            : "Apple Speech"
    }

    var state: MeetingTranscriptionState {
        MeetingTranscriptionState(statusText: transcriptionStatus)
    }

    var sttEngineState: STTEngineState {
        STTEngineState(description: displayedSTTEngine)
    }

    var microphoneState: CollectorState {
        CollectorState(statusText: microphoneProviderStatus)
    }

    var systemAudioState: CollectorState {
        CollectorState(statusText: systemAudioProviderStatus)
    }

    var fullMeetingState: CollectorState {
        CollectorState(statusText: fullMeetingProviderStatus)
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
            whisperDiagnostics =
                "microphone Whisper와 system audio Whisper를 별도 수집 중"
            whisperInputSources =
                "microphone/system audio Whisper chunks -> time-ordered full meeting"
            resetProviderStatuses()
            activeAudioSource = selectedAudioSource
            isMeetingTranscribing = true
            isStoppingMeetingTranscription = false
            currentSTTEngine = activeAudioSource == .fullMeeting
                ? fullMeetingTranscriptionProvider.preferredEngineDescription
                : "Apple Speech"
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
        let didSaveFinalTranscript: Bool
        if activeAudioSource == .fullMeeting {
            didSaveFinalTranscript = await finalizeFullMeetingTranscript()
            await microphoneTranscriptionProvider.stop()
            await systemAudioTranscriptionProvider.stop()
        } else {
            didSaveFinalTranscript = await submitFinalTranscriptsIfNeeded(
                allowsRunningStatusUpdate: false,
                force: true
            )
            await microphoneTranscriptionProvider.stop()
            await systemAudioTranscriptionProvider.stop()
            await fullMeetingTranscriptionProvider.stop()
        }

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
        let shouldDeferFullMeetingSubmission = activeAudioSource == .fullMeeting
            && isFullMeetingTranscriptSource(transcriptSource)
        if canUpdateRunningStatus {
            if update.isFinal && !shouldDeferFullMeetingSubmission {
                transcriptionStatus = "전사 저장 중"
            } else if activeAudioSource == .fullMeeting {
                transcriptionStatus = fullMeetingStatusSummary()
            } else {
                transcriptionStatus = "회의 전사 중"
            }
        }

        if update.isFinal && !shouldDeferFullMeetingSubmission {
            _ = await submitTranscriptIfNeeded(
                trimmedText,
                transcriptSource: transcriptSource,
                allowsRunningStatusUpdate: canUpdateRunningStatus
            )
        }
    }

    private func finalizeFullMeetingTranscript() async -> Bool {
        transcriptionStatus = "Local Whisper 처리 중"
        fullMeetingProviderStatus = "회의 전체: Local Whisper 처리 중"
        let finalization = await fullMeetingTranscriptionProvider
            .finalizeMeetingTranscription()

        switch finalization {
        case .whisper(let result):
            currentSTTEngine = whisperEngineDescription(
                includedSources: result.includedSources
            )
            whisperInputSources = whisperInputDescription(
                includedSources: result.includedSources
            )
            whisperDiagnostics = whisperDiagnosticsSummary(
                sourceResults: result.sourceResults,
                usedFallback: false,
                temporalMergeApplied: result.temporalMergeApplied
            )
            guard let transcriptSource = MeetingAudioSource.fullMeeting.whisperTranscriptSource else {
                return false
            }
            let normalizedText = transcriptSubmissionPolicy.normalize(
                result.text
            )
            latestTranscriptText = normalizedText
            latestTranscriptTextBySource = [transcriptSource: normalizedText]
            let didSave = await submitTranscriptIfNeeded(
                normalizedText,
                transcriptSource: transcriptSource,
                allowsRunningStatusUpdate: false,
                force: true
            )
            if didSave {
                fullMeetingProviderStatus = String(
                    format: "Local Whisper 전사 저장됨 (%.2f초)",
                    result.processingSeconds
                )
            }
            return didSave
        case .appleSpeechFallback(
            let reason,
            let sourceResults
        ):
            currentSTTEngine = "Apple Speech (fallback)"
            whisperInputSources =
                "유효한 Local Whisper source 없음 -> Apple Speech fallback"
            fullMeetingProviderStatus = "Apple Speech fallback: \(reason)"
            whisperDiagnostics = whisperDiagnosticsSummary(
                sourceResults: sourceResults,
                usedFallback: true,
                temporalMergeApplied: false
            )
            let appleSource = MeetingAudioSource.fullMeeting.primaryTranscriptSource
            guard let appleTranscript = latestTranscriptTextBySource[appleSource] else {
                transcriptionStatus = "전사 결과 없음: \(reason)"
                return false
            }
            let didSave = await submitTranscriptIfNeeded(
                appleTranscript,
                transcriptSource: appleSource,
                allowsRunningStatusUpdate: false,
                force: true
            )
            if didSave {
                fullMeetingProviderStatus = "Apple Speech fallback 저장됨: \(reason)"
            }
            return didSave
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

        if status.contains("Local Whisper 오디오 수집 계속") {
            updateProviderStatus(
                transcriptSource,
                status: statusForDisplay(status, transcriptSource: transcriptSource)
            )
            transcriptionStatus = fullMeetingStatusSummary()
            return
        }

        if status.contains("오류") || status.contains("실패") {
            if activeAudioSource == .fullMeeting {
                updateWhisperInputSources(for: status)
            }
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
        if isFullMeetingTranscriptSource(transcriptSource) {
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
        if isFullMeetingTranscriptSource(transcriptSource) {
            return "회의 전체"
        }
        return transcriptSource == MeetingAudioSource.systemAudio.primaryTranscriptSource ? "시스템 오디오" : "마이크"
    }

    private func provider(for transcriptSource: String) -> SpeechTranscriptionProvider {
        if isFullMeetingTranscriptSource(transcriptSource) {
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

    private func isFullMeetingTranscriptSource(_ transcriptSource: String) -> Bool {
        transcriptSource == MeetingAudioSource.fullMeeting.primaryTranscriptSource
            || transcriptSource == MeetingAudioSource.fullMeeting.whisperTranscriptSource
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

    private func whisperDiagnosticsSummary(
        sourceResults: [LocalWhisperSourceResult],
        usedFallback: Bool,
        temporalMergeApplied: Bool
    ) -> String {
        let includedSources = sourceResults
            .filter(\.isIncluded)
            .map(\.source.rawValue)
            .joined(separator: "+")
        let acceptedBySource = TemporaryMeetingAudioSource.allCases.map { source in
            let count = sourceResults
                .first(where: { $0.source == source })?
                .chunkDiagnostics?
                .acceptedChunkCount ?? 0
            return "\(source.rawValue)=\(count)"
        }.joined(separator: ",")
        let combinedSummary = "combined full meeting: included="
            + "\(includedSources.isEmpty ? "none" : includedSources), "
            + "temporal_merge=\(temporalMergeApplied ? "yes" : "no"), "
            + "source_accepted={\(acceptedBySource)}, "
            + "fallback=\(usedFallback ? "yes" : "no")"
        let sourceSummaries = TemporaryMeetingAudioSource.allCases.map { source in
            guard let result = sourceResults.first(where: { $0.source == source }) else {
                return "\(source.rawValue) Whisper: not attempted"
            }
            let metadata = result.audioMetadata
            let wavDuration = metadata.map {
                String(format: "%.2fs", $0.durationSeconds)
            } ?? "-"
            let captureDuration = metadata.map {
                String(format: "%.2fs", $0.captureDurationSeconds)
            } ?? "-"
            let fileSize = metadata.map {
                ByteCountFormatter.string(
                    fromByteCount: $0.fileSizeBytes,
                    countStyle: .file
                )
            } ?? "-"
            let processing = result.processingSeconds.map {
                String(format: "%.2fs", $0)
            } ?? "-"
            let textLength = result.transcriptLength.map(String.init) ?? "-"
            let chunks = result.chunkDiagnostics.map {
                "\($0.chunkCount)"
            } ?? "-"
            let acceptedChunks = result.chunkDiagnostics.map {
                "\($0.acceptedChunkCount)"
            } ?? "-"
            let rejectedChunks = result.chunkDiagnostics.map {
                "\($0.rejectedChunkCount)"
            } ?? "-"
            let rejectReasons = result.chunkDiagnostics?
                .rejectReasonSummary ?? "-"
            let debugExport = metadata?.debugExportURL?.path ?? "off"
            let status = result.isIncluded
                ? "included"
                : "skipped (\(result.failureReason ?? "unknown"))"
            return "\(source.rawValue) Whisper: \(status), wav=\(wavDuration), "
                + "capture=\(captureDuration), size=\(fileSize), "
                + "processing=\(processing), transcript=\(textLength) chars, "
                + "chunks=\(chunks), accepted=\(acceptedChunks), "
                + "rejected=\(rejectedChunks), "
                + "reject_reasons=\(rejectReasons), "
                + "debug_export=\(debugExport)"
        }
        return ([combinedSummary] + sourceSummaries).joined(separator: "\n")
    }

    private func whisperEngineDescription(
        includedSources: [TemporaryMeetingAudioSource]
    ) -> String {
        let sources = Set(includedSources)
        if sources == Set(TemporaryMeetingAudioSource.allCases) {
            return "Local Whisper (combined full meeting)"
        }
        if sources.contains(.systemAudio) {
            return "Local Whisper (system audio)"
        }
        return "Local Whisper (microphone)"
    }

    private func whisperInputDescription(
        includedSources: [TemporaryMeetingAudioSource]
    ) -> String {
        let sources = Set(includedSources)
        if sources == Set(TemporaryMeetingAudioSource.allCases) {
            return "microphone + system audio Whisper chunks -> time-ordered full meeting"
        }
        if sources.contains(.systemAudio) {
            return "system audio Whisper chunks -> time-ordered partial full meeting"
        }
        return "microphone Whisper chunks -> time-ordered partial full meeting"
    }

    private func updateWhisperInputSources(for status: String) {
        if status.contains("시스템 오디오 입력 실패") {
            whisperInputSources =
                "microphone Whisper (system audio unavailable) -> partial full meeting"
        } else if status.contains("마이크 입력 실패") {
            whisperInputSources =
                "system audio Whisper (microphone unavailable) -> partial full meeting"
        }
    }
}
