//
//  AIProviderModelService.swift
//  MwohamMac
//

import Foundation

struct AIProviderModelService {
    enum ServiceError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case noCompatibleModels
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "API Key를 먼저 입력해 주세요."
            case .invalidResponse:
                return "모델 목록 응답을 해석하지 못했습니다."
            case .noCompatibleModels:
                return "리포트 생성에 사용할 수 있는 모델을 찾지 못했습니다."
            case let .httpStatus(status):
                return "API 요청 실패: HTTP \(status)"
            }
        }
    }

    func testConnection(provider: AIProvider, key: String) async throws {
        _ = try await fetchAvailableModels(provider: provider, key: key)
    }

    func fetchAvailableModels(
        provider: AIProvider,
        key: String
    ) async throws -> [String] {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServiceError.missingAPIKey
        }

        let request = try modelListRequest(provider: provider, key: trimmed)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ServiceError.httpStatus(httpResponse.statusCode)
        }

        let models = try parseModelList(provider: provider, data: data)
        let compatible = AIProviderModelPolicy.filterReportCapableModels(
            provider: provider,
            models: models
        )
        guard !compatible.isEmpty else {
            throw ServiceError.noCompatibleModels
        }
        return compatible
    }

    private func modelListRequest(
        provider: AIProvider,
        key: String
    ) throws -> URLRequest {
        switch provider {
        case .gemini:
            var components = URLComponents(
                string: "https://generativelanguage.googleapis.com/v1beta/models"
            )!
            components.queryItems = [URLQueryItem(name: "key", value: key)]
            return URLRequest(url: components.url!)
        case .openai:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private func parseModelList(provider: AIProvider, data: Data) throws -> [String] {
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let payload else {
            throw ServiceError.invalidResponse
        }
        switch provider {
        case .gemini:
            guard let models = payload["models"] as? [[String: Any]] else {
                throw ServiceError.invalidResponse
            }
            return models.compactMap { item in
                guard let name = item["name"] as? String else {
                    return nil
                }
                return name.replacingOccurrences(of: "models/", with: "")
            }
        case .openai:
            guard let models = payload["data"] as? [[String: Any]] else {
                throw ServiceError.invalidResponse
            }
            return models.compactMap { $0["id"] as? String }
        }
    }
}

enum AIProviderBackendEnvironment {
    static func applyingAIProviderSettings(
        to environment: [String: String],
        settings: AIProviderSettings,
        keyStore: AIProviderKeyStore
    ) -> [String: String] {
        var result = environment
        let provider = settings.selectedProvider
        let model = settings.selectedModel(for: provider)

        result["AI_PROVIDER"] = provider.rawValue
        result["AI_MODEL"] = model

        switch provider {
        case .gemini:
            result["GEMINI_MODEL"] = model
            if let key = keyStore.loadAPIKey(provider: provider), !key.isEmpty {
                result["GEMINI_API_KEY"] = key
            } else {
                result.removeValue(forKey: "GEMINI_API_KEY")
            }
            result.removeValue(forKey: "OPENAI_API_KEY")
        case .openai:
            if let key = keyStore.loadAPIKey(provider: provider), !key.isEmpty {
                result["OPENAI_API_KEY"] = key
            } else {
                result.removeValue(forKey: "OPENAI_API_KEY")
            }
            result.removeValue(forKey: "GEMINI_API_KEY")
        }
        return result
    }
}
