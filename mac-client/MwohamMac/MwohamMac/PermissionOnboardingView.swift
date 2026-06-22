//
//  PermissionOnboardingView.swift
//  MwohamMac
//

import SwiftUI

struct PermissionOnboardingView: View {
    let snapshot: PermissionOnboardingSnapshot
    let isRefreshing: Bool
    let refresh: () async -> Void
    let requestMicrophoneAccess: () async -> Void
    let requestSpeechRecognitionAccess: () async -> Void
    let requestScreenRecordingAccess: () async -> Void
    let requestAccessibilityAccess: () async -> Void
    let setDebugAudioEnabled: (Bool) -> Void
    let setDevTrackingEnabled: (Bool) -> Void
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                readinessBanner
                requiredSection
                recommendedSection
                optionalSection
                footer
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
        }
        .frame(minWidth: 680, minHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("권한 설정", systemImage: "lock.shield")
                .font(.title2)
                .fontWeight(.semibold)
            Text(
                "Mwoham의 기록과 회의 전사에 필요한 권한을 확인합니다. "
                    + "먼저 앱에서 바로 요청할 수 있는 권한부터 진행합니다."
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var readinessBanner: some View {
        if snapshot.canStart {
            StatusCard("시작 가능", systemImage: "checkmark.seal.fill") {
                VStack(alignment: .leading, spacing: 8) {
                    StatusBadge(state: PermissionSetupStatus.allowed)
                    Text("필수 권한과 연결 상태가 준비되었습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if snapshot.hasRecommendedWarnings {
                        WarningBanner(
                            message: "권장 권한 없이도 사용할 수 있지만 일부 수집 정확도나 기능이 제한될 수 있습니다.",
                            title: "권장 설정 확인"
                        )
                    }
                }
            }
        } else {
            ErrorBanner(
                message: "앱 시작에 필요한 권한 또는 연결 상태를 확인해 주세요.",
                title: "필수 설정이 필요합니다"
            )
        }
    }

    private var requiredSection: some View {
        onboardingSection("필수", systemImage: "checkmark.shield") {
            PermissionOnboardingCard(
                title: "마이크",
                requirement: .required,
                status: snapshot.microphoneStatus,
                reason: "회의 음성을 수집해 전사하기 위해 필요합니다.",
                limitation: "허용하지 않으면 마이크 기반 회의 전사를 시작할 수 없습니다.",
                actionTitle: snapshot.microphoneAuthorized ? nil : "마이크 허용",
                action: requestMicrophoneAccess
            )
            PermissionOnboardingCard(
                title: "음성 인식",
                requirement: .required,
                status: snapshot.speechRecognitionStatus,
                reason: "Apple Speech 실시간 전사와 fallback에 사용합니다.",
                limitation: "허용하지 않으면 Apple Speech 실시간 전사와 fallback이 제한됩니다.",
                actionTitle: snapshot.speechRecognitionAuthorized ? nil : "음성 인식 허용",
                action: requestSpeechRecognitionAccess
            )
        }
    }

    private var recommendedSection: some View {
        onboardingSection("권장", systemImage: "star.circle") {
            PermissionOnboardingCard(
                title: "화면 기록",
                requirement: .recommended,
                status: snapshot.screenRecordingStatus,
                reason: "시스템 오디오와 화면 기반 OCR을 수집하기 위해 사용합니다.",
                limitation: "없어도 마이크 전사는 가능하지만 시스템 오디오와 OCR이 제한됩니다.",
                actionTitle: snapshot.screenRecordingAuthorized ? nil : "화면 기록 허용",
                action: requestScreenRecordingAccess
            )
            PermissionOnboardingCard(
                title: "접근성",
                requirement: .recommended,
                status: snapshot.accessibilityStatus,
                reason: "활성 앱과 창 제목 추적 정확도를 높이기 위해 사용합니다.",
                limitation: "없어도 앱을 사용할 수 있으며, 일부 창 정보가 비거나 부정확할 수 있습니다.",
                actionTitle: snapshot.accessibilityAuthorized ? nil : "접근성 허용",
                action: requestAccessibilityAccess
            )
        }
    }

    private var optionalSection: some View {
        onboardingSection("선택", systemImage: "slider.horizontal.3") {
            PermissionOnboardingCard(
                title: "debug audio 저장",
                requirement: .optional,
                status: snapshot.debugAudioStatus,
                reason: "명시적인 QA 중 Whisper 입력 WAV를 확인할 때만 사용합니다.",
                limitation: "꺼져 있어도 전사 기능에는 영향이 없습니다.",
                isOn: snapshot.debugAudioEnabled,
                setEnabled: setDebugAudioEnabled
            )
            PermissionOnboardingCard(
                title: "개발 이벤트 추적",
                requirement: .optional,
                status: snapshot.devTrackingStatus,
                reason: "repo의 개발 이벤트를 기록 세션과 함께 추적합니다.",
                limitation: "끄면 수동 및 recording 연동 Dev Tracking watcher가 시작되지 않습니다.",
                isOn: snapshot.devTrackingEnabled,
                setEnabled: setDevTrackingEnabled
            )
        }
    }

    private var footer: some View {
        HStack {
            PrimaryActionButton(
                title: "권한 상태 다시 확인",
                systemImage: "arrow.clockwise",
                isDisabled: isRefreshing
            ) {
                await refresh()
            }
            Spacer()
            Button(snapshot.canStart ? "시작하기" : "나중에 확인") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(snapshot.canStart ? "시작하기" : "나중에 확인")
        }
    }

    private func onboardingSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        StatusCard(title, systemImage: systemImage) {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
    }
}

private struct PermissionOnboardingCard<State: StatusPresentable>: View {
    let title: String
    let requirement: PermissionRequirement
    let status: State
    let reason: String
    let limitation: String
    var actionTitle: String?
    var action: (() async -> Void)?
    var isOn: Bool?
    var setEnabled: ((Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .fontWeight(.semibold)
                Text(requirement.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                StatusBadge(state: status, compact: true)
            }

            Text(reason)
                .font(.callout)
            Text(limitation)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let actionTitle, let action {
                Button {
                    Task {
                        await action()
                    }
                } label: {
                    Label(actionTitle, systemImage: "gearshape")
                }
                .accessibilityLabel(actionTitle)
            }

            if let isOn, let setEnabled {
                Toggle(
                    isOn: Binding(
                        get: { isOn },
                        set: setEnabled
                    )
                ) {
                    Text(isOn ? "켜짐" : "꺼짐")
                }
                .toggleStyle(.switch)
                .accessibilityLabel("\(title) \(isOn ? "켜짐" : "꺼짐")")
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
