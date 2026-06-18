//
//  FloatingWidgetSettingsStore.swift
//  MwohamMac
//

import Combine
import Foundation

final class FloatingWidgetSettingsStore: ObservableObject {
    static let userDefaultsKey = "floatingWidgetSettings"

    @Published var settings: FloatingWidgetSettings {
        didSet {
            let normalized = settings.normalized
            guard settings == normalized else {
                settings = normalized
                save(normalized)
                return
            }
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

    func resetToDefaults() {
        settings = .defaults
    }

    private func save(_ settings: FloatingWidgetSettings) {
        guard let data = try? encoder.encode(settings.normalized) else {
            return
        }
        userDefaults.set(data, forKey: Self.userDefaultsKey)
    }

    private static func loadSettings(
        from userDefaults: UserDefaults
    ) -> FloatingWidgetSettings {
        guard
            let data = userDefaults.data(forKey: userDefaultsKey),
            let decoded = try? JSONDecoder().decode(
                FloatingWidgetSettings.self,
                from: data
            )
        else {
            return .defaults
        }
        return decoded.normalized
    }
}
