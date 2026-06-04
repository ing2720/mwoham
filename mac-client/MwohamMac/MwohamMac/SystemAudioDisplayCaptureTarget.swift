//
//  SystemAudioDisplayCaptureTarget.swift
//  MwohamMac
//

import CoreGraphics
import Foundation
import ScreenCaptureKit

struct SystemAudioDisplayCaptureTarget {
    let display: SCDisplay
    let excludedApplications: [SCRunningApplication]

    static func make(from content: SCShareableContent) -> SystemAudioDisplayCaptureTarget? {
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first else {
            return nil
        }

        let excludedApplications = content.applications.filter { application in
            application.bundleIdentifier == Bundle.main.bundleIdentifier
                || application.processID == ProcessInfo.processInfo.processIdentifier
        }

        return SystemAudioDisplayCaptureTarget(
            display: display,
            excludedApplications: excludedApplications
        )
    }

    func makeDisplayWideFilter() -> SCContentFilter {
        SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
    }
}
