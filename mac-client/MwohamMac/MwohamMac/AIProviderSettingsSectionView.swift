//
//  AIProviderSettingsSectionView.swift
//  MwohamMac
//

import SwiftUI

struct AIProviderSettingsSectionView: View {
    @ObservedObject var store: AIProviderSettingsStore
    let keyStore: AIProviderKeyStore
    var modelService = AIProviderModelService()

    @State private var apiKeyInput = ""
    @State private var keyState = AIProviderKeyState(hasKey: false, maskedSummary: nil)
    @State private var connectionStatus: AIProviderOperationStatus = .idle
    @State private var modelFetchStatus: AIProviderOperationStatus = .idle

    var body: some View {
        StatusCard("AI 리포트 설정", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("AI Provider", selection: selectedProviderBinding) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("API Key 상태") {
                    Text(keyState.label)
                        .foregroundStyle(keyState.hasKey ? .primary : .secondary)
                }

                SecureField("API Key 입력", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 360)
                    .onChange(of: apiKeyInput) { _, _ in
                        connectionStatus = .idle
                    }

                if let providerHint {
                    Text(providerHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    PrimaryActionButton(
                        title: "연결 테스트",
                        systemImage: "checkmark.circle",
                        isDisabled: isBusy
                    ) {
                        await testConnectionAndFetchModels()
                    }

                    PrimaryActionButton(
                        title: "모델 불러오기",
                        systemImage: "arrow.down.circle",
                        isDisabled: isBusy
                    ) {
                        await fetchModels()
                    }

                    PrimaryActionButton(
                        title: "저장",
                        systemImage: "square.and.arrow.down",
                        isDisabled: isBusy
                    ) {
                        saveSettings()
                    }

                    PrimaryActionButton(
                        title: "API Key 삭제",
                        systemImage: "trash",
                        role: .destructive,
                        isDisabled: isBusy || !keyState.hasKey
                    ) {
                        deleteCurrentProviderKey()
                    }
                }

                modelPicker

                statusRows

                Text(
                    "API Key는 macOS Keychain에 저장됩니다. 모델 목록은 연결 테스트 후 자동으로 불러옵니다. "
                        + "키가 없으면 로컬 fallback 리포트로 생성됩니다. 앱 번들에는 API Key가 포함되지 않습니다."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

                Text("Provider와 모델 변경은 다음 backend 시작 또는 재시작부터 적용됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                refreshKeyState()
            }
            .onChange(of: store.selectedProvider) { _, _ in
                apiKeyInput = ""
                connectionStatus = .idle
                modelFetchStatus = .idle
                refreshKeyState()
            }
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        if store.settings.cachedModels(for: store.selectedProvider).isEmpty {
            LabeledContent("모델") {
                Text("모델 목록을 먼저 불러와 주세요.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker("모델", selection: selectedModelBinding) {
                ForEach(store.availableModelsForSelectedProvider, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("연결 테스트") {
                Text(connectionStatus.message)
                    .foregroundStyle(statusColor(connectionStatus))
            }
            LabeledContent("모델 목록") {
                Text(modelFetchStatus.message)
                    .foregroundStyle(statusColor(modelFetchStatus))
            }
        }
        .font(.footnote)
    }

    private var isBusy: Bool {
        if case .loading = connectionStatus {
            return true
        }
        if case .loading = modelFetchStatus {
            return true
        }
        return false
    }

    private var selectedProviderBinding: Binding<AIProvider> {
        Binding(
            get: { store.selectedProvider },
            set: { store.selectedProvider = $0 }
        )
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { store.selectedModel },
            set: { store.selectedModel = $0 }
        )
    }

    private var providerHint: String? {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return nil
        }
        if key.hasPrefix("sk-"), store.selectedProvider != .openai {
            return "OpenAI 키처럼 보입니다. Provider가 OpenAI인지 확인해 주세요."
        }
        if key.hasPrefix("AIza"), store.selectedProvider != .gemini {
            return "Gemini 키처럼 보입니다. Provider가 Gemini인지 확인해 주세요."
        }
        return nil
    }

    private func testConnectionAndFetchModels() async {
        connectionStatus = .loading("연결 테스트 중")
        do {
            let models = try await fetchModelsFromInputOrKeychain()
            store.setModels(models, for: store.selectedProvider)
            connectionStatus = .success("연결 성공")
            modelFetchStatus = .success("\(models.count)개 모델 확인")
        } catch {
            connectionStatus = .failure(error.localizedDescription)
        }
    }

    private func fetchModels() async {
        modelFetchStatus = .loading("모델 목록 불러오는 중")
        do {
            let models = try await fetchModelsFromInputOrKeychain()
            store.setModels(models, for: store.selectedProvider)
            modelFetchStatus = .success("\(models.count)개 모델 확인")
        } catch {
            modelFetchStatus = .failure(error.localizedDescription)
        }
    }

    private func fetchModelsFromInputOrKeychain() async throws -> [String] {
        let provider = store.selectedProvider
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey = key.isEmpty ? keyStore.loadAPIKey(provider: provider) ?? "" : key
        return try await modelService.fetchAvailableModels(provider: provider, key: resolvedKey)
    }

    private func saveSettings() {
        let provider = store.selectedProvider
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !trimmedKey.isEmpty {
                try keyStore.saveAPIKey(trimmedKey, provider: provider)
                apiKeyInput = ""
            }
            refreshKeyState()
            connectionStatus = .success("저장됨")
        } catch {
            connectionStatus = .failure(error.localizedDescription)
        }
    }

    private func deleteCurrentProviderKey() {
        do {
            try keyStore.deleteAPIKey(provider: store.selectedProvider)
            apiKeyInput = ""
            refreshKeyState()
            connectionStatus = .success("삭제됨")
        } catch {
            connectionStatus = .failure(error.localizedDescription)
        }
    }

    private func refreshKeyState() {
        keyState = AIProviderKeyState(
            hasKey: keyStore.hasAPIKey(provider: store.selectedProvider),
            maskedSummary: keyStore.maskedKeySummary(provider: store.selectedProvider)
        )
    }

    private func statusColor(_ status: AIProviderOperationStatus) -> Color {
        switch status {
        case .idle:
            return .secondary
        case .loading:
            return .secondary
        case .success:
            return .green
        case .failure:
            return .red
        }
    }
}
