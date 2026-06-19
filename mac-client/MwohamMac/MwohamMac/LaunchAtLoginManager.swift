//
//  LaunchAtLoginManager.swift
//  MwohamMac
//

import Combine
import Foundation

#if canImport(ServiceManagement)
import ServiceManagement
#endif

enum LaunchAtLoginStatus: Equatable, StatusPresentable {
    case enabled
    case disabled
    case requiresApproval
    case bundleNotFound
    case unavailable
    case unknown
    case error(String)

    var label: String {
        switch self {
        case .enabled:
            return "등록됨"
        case .disabled:
            return "해제됨"
        case .requiresApproval:
            return "승인 필요"
        case .bundleNotFound:
            return "앱 번들 확인 필요"
        case .unavailable:
            return "지원 안 됨"
        case .unknown:
            return "확인 필요"
        case .error:
            return "오류"
        }
    }

    var isRunning: Bool {
        self == .enabled
    }

    var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }

    var systemImage: String {
        switch self {
        case .enabled:
            return "checkmark.circle.fill"
        case .disabled:
            return "circle"
        case .requiresApproval:
            return "person.crop.circle.badge.exclamationmark"
        case .bundleNotFound:
            return "app.badge.checkmark"
        case .unavailable:
            return "nosign"
        case .unknown:
            return "questionmark.circle"
        case .error:
            return "xmark.octagon.fill"
        }
    }
}

struct LaunchAtLoginDiagnostics: Equatable {
    let rawStatus: String
    let bundleIdentifier: String
    let appPath: String
    let isStableAppPath: Bool

    static func current(rawStatus: String) -> LaunchAtLoginDiagnostics {
        let bundle = Bundle.main
        let appURL = bundle.bundleURL.standardizedFileURL

        return LaunchAtLoginDiagnostics(
            rawStatus: rawStatus,
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            appPath: appURL.path,
            isStableAppPath: Self.isRunnableAppBundleURL(appURL)
        )
    }

    private static func isRunnableAppBundleURL(_ appURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = appURL.path
        return appURL.pathExtension == "app"
            && !path.contains("/AppTranslocation/")
            && FileManager.default.fileExists(
                atPath: path,
                isDirectory: &isDirectory
            )
            && isDirectory.boolValue
    }
}

protocol LoginItemServicing {
    func currentStatus() throws -> LaunchAtLoginStatus
    func diagnostics() -> LaunchAtLoginDiagnostics
    func register() throws
    func unregister() throws
}

#if canImport(ServiceManagement)
@available(macOS 13.0, *)
struct ServiceManagementLoginItemService: LoginItemServicing {
    func currentStatus() throws -> LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .bundleNotFound
        @unknown default:
            return .unavailable
        }
    }

    func diagnostics() -> LaunchAtLoginDiagnostics {
        LaunchAtLoginDiagnostics.current(rawStatus: rawStatus)
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    private var rawStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "enabled"
        case .notRegistered:
            return "notRegistered"
        case .requiresApproval:
            return "requiresApproval"
        case .notFound:
            return "notFound"
        @unknown default:
            return "unknown"
        }
    }
}
#endif

struct UnsupportedLoginItemService: LoginItemServicing {
    func currentStatus() throws -> LaunchAtLoginStatus {
        .unavailable
    }

    func diagnostics() -> LaunchAtLoginDiagnostics {
        LaunchAtLoginDiagnostics.current(rawStatus: "apiUnavailable")
    }

    func register() throws {
        throw LaunchAtLoginError.unsupported
    }

    func unregister() throws {
        throw LaunchAtLoginError.unsupported
    }
}

enum LaunchAtLoginError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "이 macOS 버전에서는 로그인 시 자동 실행 설정을 사용할 수 없습니다."
        }
    }
}

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus = .unknown
    @Published private(set) var isUpdating = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var diagnostics =
        LaunchAtLoginDiagnostics.current(rawStatus: "unknown")

    private let service: LoginItemServicing

    init(service: LoginItemServicing? = nil) {
        if let service {
            self.service = service
            return
        }

        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            self.service = ServiceManagementLoginItemService()
        } else {
            self.service = UnsupportedLoginItemService()
        }
        #else
        self.service = UnsupportedLoginItemService()
        #endif
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var canChangeRegistration: Bool {
        status != .unavailable && !isUpdating
    }

    var diagnosticSummary: String {
        [
            "raw status: \(diagnostics.rawStatus)",
            "Bundle ID: \(diagnostics.bundleIdentifier)",
            "app path: \(diagnostics.appPath)",
            "stable path: \(diagnostics.isStableAppPath ? "yes" : "no")",
        ]
            .joined(separator: "\n")
    }

    func refresh() {
        guard !isUpdating else {
            return
        }
        isUpdating = true
        defer { isUpdating = false }

        do {
            status = try service.currentStatus()
            diagnostics = service.diagnostics()
            lastErrorMessage = nil
        } catch {
            status = .error(error.localizedDescription)
            diagnostics = service.diagnostics()
            lastErrorMessage =
                "자동 실행 상태 확인 실패: \(error.localizedDescription)"
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            enable()
        } else {
            disable()
        }
    }

    func enable() {
        guard !isUpdating else {
            return
        }
        isUpdating = true
        defer { isUpdating = false }

        do {
            try service.register()
            status = try service.currentStatus()
            diagnostics = service.diagnostics()
            lastErrorMessage = nil
        } catch {
            status = .error(error.localizedDescription)
            diagnostics = service.diagnostics()
            lastErrorMessage =
                "자동 실행 등록 실패: \(error.localizedDescription)"
        }
    }

    func disable() {
        guard !isUpdating else {
            return
        }
        isUpdating = true
        defer { isUpdating = false }

        do {
            try service.unregister()
            status = try service.currentStatus()
            diagnostics = service.diagnostics()
            lastErrorMessage = nil
        } catch {
            status = .error(error.localizedDescription)
            diagnostics = service.diagnostics()
            lastErrorMessage =
                "자동 실행 해제 실패: \(error.localizedDescription)"
        }
    }
}
