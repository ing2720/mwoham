//
//  AIProviderSettings.swift
//  MwohamMac
//

import Foundation

enum AIProvider: String, CaseIterable, Codable, Equatable, Identifiable {
    case gemini
    case openai

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .gemini:
            return "Gemini"
        case .openai:
            return "OpenAI"
        }
    }

    var defaultModel: String {
        switch self {
        case .gemini:
            return "gemini-2.5-flash"
        case .openai:
            return "gpt-5.2-mini"
        }
    }
}

enum AIProviderOperationStatus: Equatable {
    case idle
    case loading(String)
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .idle:
            return "대기 중"
        case let .loading(message),
             let .success(message),
             let .failure(message):
            return message
        }
    }
}

struct AIProviderSettings: Codable, Equatable {
    static let defaults = AIProviderSettings()

    var selectedProvider: AIProvider = .gemini
    var selectedModelByProvider: [AIProvider: String] = [:]
    var cachedModelsByProvider: [AIProvider: [String]] = [:]
    var lastUpdatedAtByProvider: [AIProvider: Date] = [:]

    func selectedModel(for provider: AIProvider) -> String {
        selectedModelByProvider[provider] ?? provider.defaultModel
    }

    func cachedModels(for provider: AIProvider) -> [String] {
        cachedModelsByProvider[provider] ?? []
    }

    mutating func setSelectedModel(_ model: String, for provider: AIProvider) {
        selectedModelByProvider[provider] = model
    }

    mutating func setCachedModels(_ models: [String], for provider: AIProvider) {
        cachedModelsByProvider[provider] = models
        lastUpdatedAtByProvider[provider] = Date()
        if selectedModelByProvider[provider] == nil,
           let recommended = AIProviderModelPolicy.recommendedDefaultModel(
               provider: provider,
               models: models
           ) {
            selectedModelByProvider[provider] = recommended
        }
    }
}

struct AIProviderKeyState: Equatable {
    let hasKey: Bool
    let maskedSummary: String?

    var label: String {
        if let maskedSummary {
            return "설정됨 (\(maskedSummary))"
        }
        return hasKey ? "설정됨" : "없음"
    }
}

enum AIProviderModelPolicy {
    static func filterReportCapableModels(
        provider: AIProvider,
        models: [String]
    ) -> [String] {
        let filtered = models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { model in
                switch provider {
                case .gemini:
                    return isGeminiReportModel(model)
                case .openai:
                    return isOpenAIReportModel(model)
                }
            }
        return Array(Set(filtered)).sorted {
            sortRank(provider: provider, model: $0) < sortRank(provider: provider, model: $1)
                || (
                    sortRank(provider: provider, model: $0)
                        == sortRank(provider: provider, model: $1)
                    && $0 < $1
                )
        }
    }

    static func recommendedDefaultModel(
        provider: AIProvider,
        models: [String]
    ) -> String? {
        let compatible = filterReportCapableModels(provider: provider, models: models)
        guard !compatible.isEmpty else {
            return nil
        }
        switch provider {
        case .gemini:
            return compatible.first { $0 == "gemini-2.5-flash" }
                ?? compatible.first
        case .openai:
            return compatible.first {
                $0.contains("mini") || $0.contains("fast") || $0.contains("nano")
            } ?? compatible.first
        }
    }

    private static func isGeminiReportModel(_ model: String) -> Bool {
        let value = model.lowercased()
        guard value.contains("gemini") else {
            return false
        }
        let excludedMarkers = ["embedding", "imagen", "audio", "tts", "aqa"]
        return !excludedMarkers.contains { value.contains($0) }
    }

    private static func isOpenAIReportModel(_ model: String) -> Bool {
        let value = model.lowercased()
        let excludedMarkers = [
            "embedding",
            "audio",
            "whisper",
            "tts",
            "image",
            "dall-e",
            "moderation",
            "realtime",
            "transcribe",
            "search-preview",
        ]
        guard !excludedMarkers.contains(where: { value.contains($0) }) else {
            return false
        }
        return value.hasPrefix("gpt-") || value.hasPrefix("o")
    }

    private static func sortRank(provider: AIProvider, model: String) -> Int {
        let value = model.lowercased()
        switch provider {
        case .gemini:
            if value == "gemini-2.5-flash" {
                return 0
            }
            if value.contains("flash") {
                return 1
            }
            if value.contains("pro") {
                return 2
            }
            return 10
        case .openai:
            if value.contains("mini") || value.contains("fast") || value.contains("nano") {
                return 0
            }
            if value.hasPrefix("gpt-") {
                return 1
            }
            return 10
        }
    }
}
