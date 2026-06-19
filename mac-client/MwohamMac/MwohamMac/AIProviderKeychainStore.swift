//
//  AIProviderKeychainStore.swift
//  MwohamMac
//

import Foundation
import Security

protocol AIProviderKeyStore {
    func saveAPIKey(_ key: String, provider: AIProvider) throws
    func loadAPIKey(provider: AIProvider) -> String?
    func deleteAPIKey(provider: AIProvider) throws
    func hasAPIKey(provider: AIProvider) -> Bool
    func maskedKeySummary(provider: AIProvider) -> String?
}

enum AIProviderKeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return "Keychain 작업 실패: \(status)"
        case .encodingFailed:
            return "API Key를 저장 가능한 문자열로 변환하지 못했습니다."
        }
    }
}

final class AIProviderKeychainStore: AIProviderKeyStore {
    static let service = "com.ing2720.MwohamMac.ai-provider"

    func saveAPIKey(_ key: String, provider: AIProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else {
            throw AIProviderKeychainError.encodingFailed
        }

        var query = baseQuery(provider: provider)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AIProviderKeychainError.unexpectedStatus(status)
        }
    }

    func loadAPIKey(provider: AIProvider) -> String? {
        var query = baseQuery(provider: provider)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    func deleteAPIKey(provider: AIProvider) throws {
        let status = SecItemDelete(baseQuery(provider: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIProviderKeychainError.unexpectedStatus(status)
        }
    }

    func hasAPIKey(provider: AIProvider) -> Bool {
        loadAPIKey(provider: provider) != nil
    }

    func maskedKeySummary(provider: AIProvider) -> String? {
        guard let key = loadAPIKey(provider: provider) else {
            return nil
        }
        return Self.maskedKeySummary(key)
    }

    static func maskedKeySummary(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(trimmed.suffix(4))
        return suffix.isEmpty ? "설정됨" : "••••\(suffix)"
    }

    private func baseQuery(provider: AIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}

final class InMemoryAIProviderKeyStore: AIProviderKeyStore {
    private var values: [AIProvider: String] = [:]

    func saveAPIKey(_ key: String, provider: AIProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            values[provider] = trimmed
        }
    }

    func loadAPIKey(provider: AIProvider) -> String? {
        values[provider]
    }

    func deleteAPIKey(provider: AIProvider) throws {
        values[provider] = nil
    }

    func hasAPIKey(provider: AIProvider) -> Bool {
        values[provider] != nil
    }

    func maskedKeySummary(provider: AIProvider) -> String? {
        guard let key = values[provider] else {
            return nil
        }
        return AIProviderKeychainStore.maskedKeySummary(key)
    }
}
