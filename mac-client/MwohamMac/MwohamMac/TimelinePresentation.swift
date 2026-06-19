//
//  TimelinePresentation.swift
//  MwohamMac
//

import Foundation

enum TimelineFilter: String, CaseIterable, Identifiable {
    case all
    case appActivity
    case memo
    case meeting
    case dev
    case important

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .all:
            return "전체"
        case .appActivity:
            return "앱 활동"
        case .memo:
            return "메모"
        case .meeting:
            return "회의"
        case .dev:
            return "개발 이벤트"
        case .important:
            return "중요 이벤트"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "list.bullet"
        case .appActivity:
            return "macwindow"
        case .memo:
            return "note.text"
        case .meeting:
            return "waveform"
        case .dev:
            return "hammer"
        case .important:
            return "star.fill"
        }
    }
}

enum TimelineEventCategory: String, StatusPresentable {
    case appActivity
    case memo
    case meeting
    case dev
    case report
    case other

    var label: String {
        switch self {
        case .appActivity:
            return "앱 활동"
        case .memo:
            return "메모"
        case .meeting:
            return "회의"
        case .dev:
            return "개발 이벤트"
        case .report:
            return "리포트"
        case .other:
            return "기타"
        }
    }

    var isRunning: Bool {
        false
    }

    var isError: Bool {
        false
    }

    var systemImage: String {
        switch self {
        case .appActivity:
            return "macwindow"
        case .memo:
            return "note.text"
        case .meeting:
            return "waveform"
        case .dev:
            return "hammer"
        case .report:
            return "doc.text"
        case .other:
            return "circle"
        }
    }
}

struct TimelineDisplayItem: Identifiable, Equatable {
    let id: String
    let rawType: String
    let timestamp: Date
    let endedAt: Date?
    let category: TimelineEventCategory
    let title: String
    let description: String
    let sourceText: String?
    let appName: String?
    let windowTitle: String?
    let durationSeconds: Int?
    let signalLevel: String?
    let hiddenByDefault: Bool
    let eventCount: Int?
    let isImportant: Bool
    var isFoldedNoise: Bool
    var noiseReason: String?
    let detailLines: [String]

    var timeText: String {
        Self.timeFormatter.string(from: timestamp)
    }

    var durationText: String? {
        guard let durationSeconds, durationSeconds > 0 else {
            return nil
        }
        if durationSeconds < 60 {
            return "\(durationSeconds)초"
        }
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        if seconds == 0 {
            return "\(minutes)분"
        }
        return "\(minutes)분 \(seconds)초"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct TimelineDisplayGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let items: [TimelineDisplayItem]
    let foldedItems: [TimelineDisplayItem]
    let totalCount: Int
    let importantCount: Int
    let isReportCandidate: Bool

    var isEmpty: Bool {
        items.isEmpty && foldedItems.isEmpty
    }
}

enum TimelineDateParser {
    static func parse(_ value: String) -> Date? {
        if let date = isoFormatterWithFractionalSeconds.date(from: value) {
            return date
        }
        if let date = isoFormatter.date(from: value) {
            return date
        }
        if let date = utcFormatterWithMicroseconds.date(from: value) {
            return date
        }
        if let date = utcFormatterWithMilliseconds.date(from: value) {
            return date
        }
        return utcFormatter.date(from: value)
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

    private static let utcFormatterWithMicroseconds: DateFormatter = {
        makeUTCFormatter(format: "yyyy-MM-dd'T'HH:mm:ss.SSSSSS")
    }()

    private static let utcFormatterWithMilliseconds: DateFormatter = {
        makeUTCFormatter(format: "yyyy-MM-dd'T'HH:mm:ss.SSS")
    }()

    private static let utcFormatter: DateFormatter = {
        makeUTCFormatter(format: "yyyy-MM-dd'T'HH:mm:ss")
    }()

    private static func makeUTCFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}

enum TimelinePresentationBuilder {
    static func groups(
        for items: [TimelineDisplayItem],
        filter: TimelineFilter,
        calendar: Calendar = .current
    ) -> [TimelineDisplayGroup] {
        let sortedItems = items.sorted { $0.timestamp < $1.timestamp }
        let filteredItems = sortedItems.filter { item in
            matches(item, filter: filter)
        }
        let foldedItems = markFoldedNoise(
            filteredItems,
            calendar: calendar
        )
        let grouped = Dictionary(grouping: foldedItems) { item in
            period(for: item.timestamp, calendar: calendar)
        }

        return TimelinePeriod.displayDescending.compactMap { period in
            guard let periodItems = grouped[period], !periodItems.isEmpty else {
                return nil
            }
            let splitItems = splitVisibleAndFoldedItems(periodItems)
            let importantCount = periodItems.filter(\.isImportant).count
            let isReportCandidate =
                importantCount > 0
                || periodItems.contains { item in
                    item.category == .meeting || item.category == .memo
                        || item.category == .dev
                }

            return TimelineDisplayGroup(
                id: period.rawValue,
                title: period.title,
                systemImage: period.systemImage,
                items: Array(splitItems.visible.reversed()),
                foldedItems: Array(splitItems.folded.reversed()),
                totalCount: periodItems.count,
                importantCount: importantCount,
                isReportCandidate: isReportCandidate
            )
        }
    }

    static func matches(
        _ item: TimelineDisplayItem,
        filter: TimelineFilter
    ) -> Bool {
        switch filter {
        case .all:
            return true
        case .appActivity:
            return item.category == .appActivity
        case .memo:
            return item.category == .memo
        case .meeting:
            return item.category == .meeting
        case .dev:
            return item.category == .dev
        case .important:
            return item.isImportant
        }
    }

    private static func markFoldedNoise(
        _ items: [TimelineDisplayItem],
        calendar: Calendar
    ) -> [TimelineDisplayItem] {
        var previousSignature: String?
        var previousDate: Date?

        return items.map { item in
            var copy = item
            let signature = noiseSignature(for: item)
            let repeatedQuickly =
                signature == previousSignature
                && previousDate.map {
                    abs(item.timestamp.timeIntervalSince($0)) < 300
                } == true

            if copy.hiddenByDefault {
                copy.isFoldedNoise = true
                copy.noiseReason = copy.noiseReason ?? "낮은 신호"
            } else if isEmptyEvent(item) {
                copy.isFoldedNoise = true
                copy.noiseReason = "빈 이벤트"
            } else if isShortActivity(item) {
                copy.isFoldedNoise = true
                copy.noiseReason = "짧은 앱 전환"
            } else if repeatedQuickly {
                copy.isFoldedNoise = true
                copy.noiseReason = "반복 앱/창"
            }

            previousSignature = signature
            previousDate = item.timestamp
            return copy
        }
    }

    private static func splitVisibleAndFoldedItems(
        _ periodItems: [TimelineDisplayItem]
    ) -> (visible: [TimelineDisplayItem], folded: [TimelineDisplayItem]) {
        let visible = periodItems.filter { !$0.isFoldedNoise }
        let folded = periodItems.filter(\.isFoldedNoise)
        guard visible.isEmpty, !folded.isEmpty else {
            return (visible, folded)
        }

        let previewItems = Array(folded.prefix(3))
        let remainingFoldedItems = Array(folded.dropFirst(previewItems.count))
        return (previewItems, remainingFoldedItems)
    }

    private static func isShortActivity(_ item: TimelineDisplayItem) -> Bool {
        guard item.category == .appActivity,
              let durationSeconds = item.durationSeconds else {
            return false
        }
        return durationSeconds > 0 && durationSeconds < 30
    }

    private static func isEmptyEvent(_ item: TimelineDisplayItem) -> Bool {
        item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && item.description.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    private static func noiseSignature(for item: TimelineDisplayItem) -> String {
        [
            item.category.rawValue,
            item.appName ?? "",
            item.windowTitle ?? "",
            item.title,
        ].joined(separator: "|")
    }

    private static func period(
        for date: Date,
        calendar: Calendar
    ) -> TimelinePeriod {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<12:
            return .morning
        case 12..<18:
            return .afternoon
        case 18..<22:
            return .evening
        default:
            return .night
        }
    }
}

private enum TimelinePeriod: String, CaseIterable {
    case morning
    case afternoon
    case evening
    case night

    static let displayDescending: [TimelinePeriod] = [
        .night,
        .evening,
        .afternoon,
        .morning,
    ]

    var title: String {
        switch self {
        case .morning:
            return "오전"
        case .afternoon:
            return "오후"
        case .evening:
            return "저녁"
        case .night:
            return "밤"
        }
    }

    var systemImage: String {
        switch self {
        case .morning:
            return "sunrise"
        case .afternoon:
            return "sun.max"
        case .evening:
            return "sunset"
        case .night:
            return "moon"
        }
    }
}
