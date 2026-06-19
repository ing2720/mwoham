#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/mac-client/MwohamMac/MwohamMac"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mwoham-ai-provider.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/AIProviderSettingsHarness.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

func makeDefaults(_ name: String) -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: name) else {
        fatalError("failed to create test UserDefaults")
    }
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@main
enum AIProviderSettingsHarness {
    static func main() {
        expect(AIProvider.gemini.displayName == "Gemini", "Gemini display name")
        expect(AIProvider.openai.displayName == "OpenAI", "OpenAI display name")
        expect(AIProvider.gemini.defaultModel == "gemini-2.5-flash", "Gemini default model")
        expect(AIProvider.openai.defaultModel.contains("mini"), "OpenAI default favors mini")
        expect(
            AIProviderBackendApplyPolicy.message(
                hasPendingBackendRestart: false,
                canRestartBackend: false
            ).contains("재시작"),
            "default backend apply message mentions restart"
        )
        expect(
            AIProviderBackendApplyPolicy.message(
                hasPendingBackendRestart: true,
                canRestartBackend: true
            ).contains("web report"),
            "owned backend pending message mentions web report"
        )
        expect(
            AIProviderBackendApplyPolicy.message(
                hasPendingBackendRestart: true,
                canRestartBackend: false
            ).contains("외부 backend 재시작"),
            "external backend pending message mentions external restart"
        )
        expect(
            AIProviderBackendApplyPolicy.isRestartDisabled(
                hasPendingBackendRestart: true,
                canRestartBackend: true,
                isBusy: false
            ) == false,
            "restart is enabled when pending and owned backend can restart"
        )
        expect(
            AIProviderBackendApplyPolicy.isRestartDisabled(
                hasPendingBackendRestart: true,
                canRestartBackend: false,
                isBusy: false
            ),
            "restart is disabled for external backend"
        )

        let geminiModels = AIProviderModelPolicy.filterReportCapableModels(
            provider: .gemini,
            models: [
                "models/gemini-embedding-001",
                "gemini-2.5-pro",
                "gemini-2.5-flash",
                "imagen-3",
                "gemini-2.0-flash",
            ]
        )
        expect(geminiModels.first == "gemini-2.5-flash", "Gemini flash should be first")
        expect(!geminiModels.contains("models/gemini-embedding-001"), "Gemini embedding excluded")
        expect(!geminiModels.contains("imagen-3"), "Gemini image model excluded")

        let openAIModels = AIProviderModelPolicy.filterReportCapableModels(
            provider: .openai,
            models: [
                "text-embedding-3-small",
                "gpt-5.2",
                "gpt-5.2-mini",
                "gpt-image-1",
                "whisper-1",
                "o4-mini",
            ]
        )
        expect(openAIModels.first?.contains("mini") == true, "OpenAI mini model should sort first")
        expect(!openAIModels.contains("text-embedding-3-small"), "OpenAI embedding excluded")
        expect(!openAIModels.contains("gpt-image-1"), "OpenAI image model excluded")
        expect(!openAIModels.contains("whisper-1"), "OpenAI audio model excluded")

        let suiteName = "mwoham.ai-provider-settings.\(UUID().uuidString)"
        let defaults = makeDefaults(suiteName)
        let store = AIProviderSettingsStore(userDefaults: defaults)
        expect(store.selectedProvider == .gemini, "default provider should be Gemini")
        expect(store.selectedModel == "gemini-2.5-flash", "default model should be provider default")
        store.selectedProvider = .openai
        store.setModels(["gpt-5.2", "gpt-5.2-mini"], for: .openai)
        expect(store.selectedModel == "gpt-5.2-mini", "model list should auto-select recommended")

        let reloaded = AIProviderSettingsStore(userDefaults: defaults)
        expect(reloaded.selectedProvider == .openai, "provider should persist")
        expect(reloaded.selectedModel == "gpt-5.2-mini", "model should persist")

        let keyStore = InMemoryAIProviderKeyStore()
        try! keyStore.saveAPIKey("gemini-secret-1234", provider: .gemini)
        try! keyStore.saveAPIKey("openai-secret-9876", provider: .openai)
        expect(keyStore.hasAPIKey(provider: .gemini), "Gemini key should exist")
        expect(keyStore.maskedKeySummary(provider: .gemini) == "••••1234", "Gemini key masked")
        try! keyStore.deleteAPIKey(provider: .gemini)
        expect(!keyStore.hasAPIKey(provider: .gemini), "Gemini key should be deleted")
        expect(keyStore.hasAPIKey(provider: .openai), "OpenAI key should remain")

        var settings = AIProviderSettings.defaults
        settings.selectedProvider = .gemini
        settings.setSelectedModel("gemini-2.5-flash", for: .gemini)
        try! keyStore.saveAPIKey("gemini-secret-1234", provider: .gemini)
        var environment = AIProviderBackendEnvironment.applyingAIProviderSettings(
            to: [:],
            settings: settings,
            keyStore: keyStore
        )
        expect(environment["AI_PROVIDER"] == "gemini", "Gemini AI_PROVIDER")
        expect(environment["AI_MODEL"] == "gemini-2.5-flash", "Gemini AI_MODEL")
        expect(environment["GEMINI_MODEL"] == "gemini-2.5-flash", "Gemini compatibility model")
        expect(environment["GEMINI_API_KEY"] == "gemini-secret-1234", "Gemini key injected")
        expect(environment["OPENAI_API_KEY"] == nil, "OpenAI key not injected for Gemini")

        settings.selectedProvider = .openai
        settings.setSelectedModel("gpt-5.2-mini", for: .openai)
        environment = AIProviderBackendEnvironment.applyingAIProviderSettings(
            to: [:],
            settings: settings,
            keyStore: keyStore
        )
        expect(environment["AI_PROVIDER"] == "openai", "OpenAI AI_PROVIDER")
        expect(environment["AI_MODEL"] == "gpt-5.2-mini", "OpenAI AI_MODEL")
        expect(environment["OPENAI_API_KEY"] == "openai-secret-9876", "OpenAI key injected")
        expect(environment["GEMINI_API_KEY"] == nil, "Gemini key not injected for OpenAI")

        try! keyStore.deleteAPIKey(provider: .openai)
        environment = AIProviderBackendEnvironment.applyingAIProviderSettings(
            to: [:],
            settings: settings,
            keyStore: keyStore
        )
        expect(environment["AI_PROVIDER"] == "openai", "Provider remains without key")
        expect(environment["OPENAI_API_KEY"] == nil, "Missing key should not inject env")

        defaults.removePersistentDomain(forName: suiteName)
        print("AIProvider settings harness passed")
    }
}
SWIFT

swiftc \
    -module-cache-path "$WORK_DIR/module-cache" \
    "$WORK_DIR/AIProviderSettingsHarness.swift" \
    "$APP_DIR/AIProviderSettings.swift" \
    "$APP_DIR/AIProviderSettingsStore.swift" \
    "$APP_DIR/AIProviderKeychainStore.swift" \
    "$APP_DIR/AIProviderModelService.swift" \
    -o "$WORK_DIR/ai_provider_settings_harness"

"$WORK_DIR/ai_provider_settings_harness"

cat > "$WORK_DIR/UIStubs.swift" <<'SWIFT'
import SwiftUI

struct StatusCard<Content: View>: View {
    let title: String
    let systemImage: String?
    let content: Content

    init(
        _ title: String,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        content
    }
}

struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    var isDisabled = false
    var fillsWidth = false
    let action: () async -> Void

    var body: some View {
        Button(role: role) {
            Task {
                await action()
            }
        } label: {
            Text(title)
        }
        .disabled(isDisabled)
    }
}
SWIFT

swiftc \
    -typecheck \
    -parse-as-library \
    -module-cache-path "$WORK_DIR/module-cache" \
    "$APP_DIR/AIProviderSettings.swift" \
    "$APP_DIR/AIProviderSettingsStore.swift" \
    "$APP_DIR/AIProviderKeychainStore.swift" \
    "$APP_DIR/AIProviderModelService.swift" \
    "$APP_DIR/AIProviderSettingsSectionView.swift" \
    "$WORK_DIR/UIStubs.swift"
