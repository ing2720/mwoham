//
//  MeetingTranscriptSubmissionPolicy.swift
//  MwohamMac
//

import Foundation

struct MeetingTranscriptSubmissionPolicy {
    let minimumStorageCharacterCount = 2
    let minimumSubmissionInterval: TimeInterval = 2

    func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isMeaningfulForSubmission(_ text: String) -> Bool {
        compact(text).count >= minimumStorageCharacterCount
    }

    func shouldSkipSubmission(
        text: String,
        lastSubmittedText: String,
        lastSubmittedAt: Date?,
        now: Date = Date(),
        force: Bool = false
    ) -> Bool {
        let normalizedText = normalize(text)
        guard !normalizedText.isEmpty, normalizedText != lastSubmittedText else {
            return true
        }
        guard isMeaningfulForSubmission(normalizedText) else {
            return true
        }
        if !force,
           let lastSubmittedAt,
           now.timeIntervalSince(lastSubmittedAt) < minimumSubmissionInterval {
            return true
        }
        return false
    }

    private func compact(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
}
