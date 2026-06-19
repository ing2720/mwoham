//
//  TimelineViewModel.swift
//  MwohamMac
//

import Combine
import Foundation

@MainActor
final class TimelineViewModel: ObservableObject {
    @Published var selectedFilter: TimelineFilter = .all {
        didSet {
            rebuildGroups()
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var responseDateText = "-"
    @Published private(set) var totalCount = 0
    @Published private(set) var groups: [TimelineDisplayGroup] = []

    private let localApiClient: LocalApiClient
    private var allItems: [TimelineDisplayItem] = []

    var hasLoadedItems: Bool {
        totalCount > 0
    }

    var hasFilterResults: Bool {
        !groups.isEmpty
    }

    init(localApiClient: LocalApiClient) {
        self.localApiClient = localApiClient
    }

    func refresh() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let response = try await localApiClient.fetchTimelineDetail()
            responseDateText = response.date
            totalCount = response.total
            allItems = response.items.compactMap(Self.makeDisplayItem)
            rebuildGroups()
        } catch {
            errorMessage = error.localizedDescription
            groups = []
        }

        isLoading = false
    }

    private func rebuildGroups() {
        groups = TimelinePresentationBuilder.groups(
            for: allItems,
            filter: selectedFilter
        )
    }

    private static func makeDisplayItem(
        from response: TimelineItemResponse
    ) -> TimelineDisplayItem? {
        guard let timestamp = parseDate(response.timestamp) else {
            return nil
        }
        let endedAt = response.endedAt.flatMap(parseDate)
        let category = category(for: response.type)
        let title = title(for: response, category: category)
        let description = description(for: response, title: title)
        let sourceText = sourceText(for: response)
        let important = isImportant(response, category: category)
        let details = detailLines(for: response, endedAt: endedAt)

        return TimelineDisplayItem(
            id: "\(response.type)-\(response.id)",
            rawType: response.type,
            timestamp: timestamp,
            endedAt: endedAt,
            category: category,
            title: title,
            description: description,
            sourceText: sourceText,
            appName: response.appName,
            windowTitle: response.windowTitle,
            durationSeconds: response.durationSeconds,
            signalLevel: response.signalLevel,
            hiddenByDefault: response.hiddenByDefault ?? false,
            eventCount: response.eventCount,
            isImportant: important,
            isFoldedNoise: response.hiddenByDefault ?? false,
            noiseReason: noiseReasonText(response.noiseReason),
            detailLines: details
        )
    }

    private static func category(for rawType: String) -> TimelineEventCategory {
        switch rawType {
        case "activity_segment", "event", "screen_ocr":
            return .appActivity
        case "memo":
            return .memo
        case "meeting", "transcript":
            return .meeting
        case "dev_event":
            return .dev
        case "report", "daily_report":
            return .report
        default:
            return .other
        }
    }

    private static func title(
        for response: TimelineItemResponse,
        category: TimelineEventCategory
    ) -> String {
        if let displayLabel = clean(response.displayLabel),
           !displayLabel.isEmpty {
            return displayLabel
        }

        switch category {
        case .appActivity:
            if let displayTitle = clean(response.displayTitle) {
                return displayTitle
            }
            if let appName = clean(response.appName),
               let windowTitle = clean(response.windowTitle),
               !windowTitle.isEmpty {
                return "\(appName) / \(windowTitle)"
            }
            if let appName = clean(response.appName) {
                return appName
            }
            return clean(response.content) ?? "앱 활동"
        case .memo:
            return "수동 메모"
        case .meeting:
            return response.type == "transcript" ? "회의 전사" : "회의"
        case .dev:
            if let eventType = clean(response.eventType) {
                return devEventTitle(eventType)
            }
            return "개발 이벤트"
        case .report:
            return "리포트"
        case .other:
            return clean(response.content) ?? "기타 이벤트"
        }
    }

    private static func description(
        for response: TimelineItemResponse,
        title: String
    ) -> String {
        let content = clean(response.content) ?? ""
        if content.isEmpty || content == title {
            if let durationSeconds = response.durationSeconds,
               durationSeconds > 0 {
                return "지속 시간 \(durationText(durationSeconds))"
            }
            return ""
        }

        return content
    }

    private static func sourceText(
        for response: TimelineItemResponse
    ) -> String? {
        let candidates = [
            response.source,
            response.appName,
            response.branch,
            response.repoPath?.split(separator: "/").last.map(String.init),
        ]

        return candidates.compactMap(clean).first
    }

    private static func isImportant(
        _ response: TimelineItemResponse,
        category: TimelineEventCategory
    ) -> Bool {
        switch category {
        case .memo, .meeting, .report:
            return true
        case .dev:
            let status = response.status?.lowercased() ?? ""
            let eventType = response.eventType?.lowercased() ?? ""
            return status.contains("fail")
                || status.contains("error")
                || eventType.contains("command")
                || eventType.contains("commit")
                || eventType.contains("test")
        case .appActivity:
            if response.signalLevel == "high_signal" {
                return true
            }
            if response.hiddenByDefault == true {
                return false
            }
            return (response.durationSeconds ?? 0) >= 900
        case .other:
            return false
        }
    }

    private static func detailLines(
        for response: TimelineItemResponse,
        endedAt: Date?
    ) -> [String] {
        var lines: [String] = []

        if let source = clean(response.source) {
            lines.append("source: \(source)")
        }
        if let eventType = clean(response.eventType) {
            lines.append("event: \(eventType)")
        }
        if let command = clean(response.command) {
            lines.append("command: \(command)")
        }
        if let status = clean(response.status) {
            lines.append("status: \(status)")
        }
        if let branch = clean(response.branch) {
            lines.append("branch: \(branch)")
        }
        if let durationSeconds = response.durationSeconds,
           durationSeconds > 0 {
            lines.append("duration: \(durationText(durationSeconds))")
        }
        if let sampleCount = response.sampleCount,
           sampleCount > 0 {
            lines.append("samples: \(sampleCount)")
        }
        if let eventCount = response.eventCount,
           eventCount > 1 {
            lines.append("events: \(eventCount)")
        }
        if let signalLevel = clean(response.signalLevel) {
            lines.append("signal: \(signalLevel)")
        }
        if let noiseReason = noiseReasonText(response.noiseReason) {
            lines.append("noise: \(noiseReason)")
        }
        if let endedAt {
            lines.append("ended: \(detailDateFormatter.string(from: endedAt))")
        }

        return lines
    }

    private static func devEventTitle(_ eventType: String) -> String {
        switch eventType {
        case "command_started":
            return "명령 실행"
        case "command_finished", "command_succeeded":
            return "명령 성공"
        case "command_failed":
            return "명령 실패"
        case "git_commit":
            return "Git 커밋"
        case "git_change":
            return "Git 변경"
        default:
            return eventType
                .replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func durationText(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)초"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 {
            return "\(minutes)분"
        }
        return "\(minutes)분 \(remainder)초"
    }

    private static func noiseReasonText(_ reason: String?) -> String? {
        switch clean(reason) {
        case "short_app_switch":
            return "짧은 앱 전환"
        case "weak_window_title":
            return "의미 약한 창 제목"
        case "repeated_app_window":
            return "반복 앱/창"
        case "weak_app_context":
            return "앱 정보 부족"
        case let value?:
            return value
        case nil:
            return nil
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = isoFormatterWithFractionalSeconds.date(from: value) {
            return date
        }
        if let date = isoFormatter.date(from: value) {
            return date
        }
        return looseDateFormatter.date(from: value)
    }

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let looseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
