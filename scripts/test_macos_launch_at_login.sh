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
    expect(!manager.isEnabled, "disabled status should not be enabled")
    expect(manager.lastErrorMessage == nil, "refresh should clear errors")

    manager.setEnabled(true)
    expect(manager.status == .enabled, "enable should register login item")
    expect(manager.isEnabled, "enabled status should be enabled")

    manager.setEnabled(false)
    expect(manager.status == .disabled, "disable should unregister login item")
    expect(!manager.isEnabled, "disabled status should not be enabled")

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
