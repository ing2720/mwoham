#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/mac-client/MwohamMac/MwohamMac"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mwoham-launch-login.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/LaunchAtLoginHarness.swift" <<'SWIFT'
import Foundation

enum HarnessError: LocalizedError {
    case registerFailed
    case unregisterFailed
    case statusFailed

    var errorDescription: String? {
        switch self {
        case .registerFailed:
            return "register failed"
        case .unregisterFailed:
            return "unregister failed"
        case .statusFailed:
            return "status failed"
        }
    }
}

final class FakeLoginItemService: LoginItemServicing {
    var status: LaunchAtLoginStatus
    var registerError: Error?
    var unregisterError: Error?
    var statusError: Error?

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func currentStatus() throws -> LaunchAtLoginStatus {
        if let statusError {
            throw statusError
        }
        return status
    }

    func diagnostics() -> LaunchAtLoginDiagnostics {
        LaunchAtLoginDiagnostics(
            rawStatus: rawDiagnosticStatus,
            bundleIdentifier: "com.ing2720.MwohamMac",
            appPath: "/Users/a/Applications/MwohamMac.app",
            isStableAppPath: true
        )
    }

    func register() throws {
        if let registerError {
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        if let unregisterError {
            throw unregisterError
        }
        status = .disabled
    }

    private var rawDiagnosticStatus: String {
        switch status {
        case .enabled:
            return "enabled"
        case .disabled:
            return "notRegistered"
        case .requiresApproval:
            return "requiresApproval"
        case .bundleNotFound:
            return "notFound"
        case .unavailable:
            return "apiUnavailable"
        case .unknown:
            return "unknown"
        case .error:
            return "error"
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

@MainActor
func runHarness() {
    let service = FakeLoginItemService(status: .disabled)
    let manager = LaunchAtLoginManager(service: service)

    manager.refresh()
    expect(manager.status == .disabled, "refresh should read disabled status")
    expect(manager.status.label == "해제됨", "disabled label should be Korean off state")
    expect(!manager.isEnabled, "disabled status should not be enabled")
    expect(manager.lastErrorMessage == nil, "refresh should clear errors")
    expect(
        manager.diagnostics.rawStatus == "notRegistered",
        "disabled status should keep raw notRegistered diagnostic"
    )

    manager.setEnabled(true)
    expect(manager.status == .enabled, "enable should register login item")
    expect(manager.isEnabled, "enabled status should be enabled")

    manager.setEnabled(false)
    expect(manager.status == .disabled, "disable should unregister login item")
    expect(!manager.isEnabled, "disabled status should not be enabled")

    let requiresApprovalManager =
        LaunchAtLoginManager(
            service: FakeLoginItemService(status: .requiresApproval)
        )
    requiresApprovalManager.refresh()
    expect(
        requiresApprovalManager.status == .requiresApproval,
        "requires approval should stay distinct from unsupported"
    )
    expect(
        requiresApprovalManager.status.label == "승인 필요",
        "requires approval should expose approval label"
    )

    let notFoundManager =
        LaunchAtLoginManager(
            service: FakeLoginItemService(status: .bundleNotFound)
        )
    notFoundManager.refresh()
    expect(
        notFoundManager.status == .bundleNotFound,
        "notFound should map to bundle check status"
    )
    expect(
        notFoundManager.status.label == "앱 번들 확인 필요",
        "notFound should not display unsupported"
    )
    expect(
        notFoundManager.canChangeRegistration,
        "bundle check status should not disable the toggle"
    )

    let failingRegister = FakeLoginItemService(status: .disabled)
    failingRegister.registerError = HarnessError.registerFailed
    let failingRegisterManager =
        LaunchAtLoginManager(service: failingRegister)
    failingRegisterManager.enable()
    expect(failingRegisterManager.status.isError, "register failure should set error status")
    expect(
        failingRegisterManager.lastErrorMessage?.contains("자동 실행 등록 실패") == true,
        "register failure should expose Korean error title"
    )

    let failingUnregister = FakeLoginItemService(status: .enabled)
    failingUnregister.unregisterError = HarnessError.unregisterFailed
    let failingUnregisterManager =
        LaunchAtLoginManager(service: failingUnregister)
    failingUnregisterManager.disable()
    expect(failingUnregisterManager.status.isError, "unregister failure should set error status")
    expect(
        failingUnregisterManager.lastErrorMessage?.contains("자동 실행 해제 실패") == true,
        "unregister failure should expose Korean error title"
    )

    let unsupportedManager =
        LaunchAtLoginManager(service: UnsupportedLoginItemService())
    unsupportedManager.refresh()
    expect(
        unsupportedManager.status == .unavailable,
        "unsupported service should report unavailable"
    )
    expect(
        unsupportedManager.status.label == "지원 안 됨",
        "only unsupported service should display unsupported"
    )
    expect(
        !unsupportedManager.canChangeRegistration,
        "unsupported API should disable the toggle"
    )

    print("LaunchAtLoginManager harness passed")
}

@main
enum LaunchAtLoginHarness {
    static func main() async {
        await MainActor.run {
            runHarness()
        }
    }
}
SWIFT

swiftc \
    -module-cache-path "$WORK_DIR/module-cache" \
    "$WORK_DIR/LaunchAtLoginHarness.swift" \
    "$APP_DIR/StatusTypes.swift" \
    "$APP_DIR/LaunchAtLoginManager.swift" \
    -o "$WORK_DIR/launch_at_login_harness"

"$WORK_DIR/launch_at_login_harness"
