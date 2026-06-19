//
//  AIProviderSettingsStore.swift
//  MwohamMac
//

import Combine
import Foundation

final class AIProviderSettingsStore: ObservableObject {
    static let userDefaultsKey = "aiProviderSettings"

    @Published var settings: AIProviderSettings {
        didSet {
            save(settings)
        }
    }

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.settings = Self.loadSettings(from: userDefaults)
    }

    var selectedProvider: AIProvider {
        get { settings.selectedProvider }
        set { settings.selectedProvider = newValue }
    }

    var selectedModel: String {
        get { settings.selectedModel(for: settings.selectedProvider) }
        set {
            settings.setSelectedModel(newValue, for: settings.selectedProvider)
        }
    }

    var availableModelsForSelectedProvider: [String] {
        let cached = settings.cachedModels(for: settings.selectedProvider)
        if cached.contains(selectedModel) {
            return cached
        }
        return cached.isEmpty ? [selectedModel] : [selectedModel] + cached
    }

    func setModels(_ models: [String], for provider: AIProvider) {
        let compatible = AIProviderModelPolicy.filterReportCapableModels(
            provider: provider,
            models: models
        )
        settings.setCachedModels(compatible, for: provider)
    }

    func resetToDefaults() {
        settings = .defaults
    }

    private func save(_ settings: AIProviderSettings) {
        guard let data = try? encoder.encode(settings) else {
            return
        }
        userDefaults.set(data, forKey: Self.userDefaultsKey)
    }

    private static func loadSettings(
        from userDefaults: UserDefaults
    ) -> AIProviderSettings {
        guard
            let data = userDefaults.data(forKey: userDefaultsKey),
            let decoded = try? JSONDecoder().decode(AIProviderSettings.self, from: data)
        else {
            return .defaults
        }
        return decoded
    }
}
