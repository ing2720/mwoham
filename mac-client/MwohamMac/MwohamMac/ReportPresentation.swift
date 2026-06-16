//
//  ReportPresentation.swift
//  MwohamMac
//

import Foundation

enum ReportMode: String, CaseIterable, Identifiable, StatusPresentable {
    case detailed
    case simple
    case other

    init(apiValue: String) {
        switch apiValue {
        case "detailed":
            self = .detailed
        case "simple":
            self = .simple
        default:
            self = .other
        }
    }

    var id: String {
        rawValue
    }

    var apiValue: String {
        switch self {
        case .detailed:
            return "detailed"
        case .simple:
            return "simple"
        case .other:
            return "other"
        }
    }

    var label: String {
        switch self {
        case .detailed:
            return "상세 리포트"
        case .simple:
            return "간단 리포트"
        case .other:
            return "리포트"
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
        case .detailed:
            return "doc.text.magnifyingglass"
        case .simple:
            return "doc.text"
        case .other:
            return "doc"
        }
    }
}

enum ReportCreator: String, StatusPresentable {
    case ai
    case system
    case user
    case other

    init(apiValue: String) {
        switch apiValue {
        case "ai":
            self = .ai
        case "system":
            self = .system
        case "user":
            self = .user
        default:
            self = .other
        }
    }

    var label: String {
        switch self {
        case .ai:
            return "AI 생성"
        case .system:
            return "시스템 생성"
        case .user:
            return "사용자 수정"
        case .other:
            return "생성자 확인 필요"
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
        case .ai:
            return "sparkles"
        case .system:
            return "gearshape"
        case .user:
            return "person"
        case .other:
            return "questionmark.circle"
        }
    }
}

struct ReportListItem: Identifiable, Equatable {
    let id: Int
    let dateText: String
    let mode: ReportMode
    let title: String
    let preview: String
    let createdAtText: String
    let updatedAtText: String
    let updatedAtSortKey: String
    let isLatest: Bool
}

struct ReportDateGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let dateText: String
    let isToday: Bool
    let reports: [ReportListItem]
}

struct ReportPresentationInput: Identifiable, Equatable {
    let id: Int
    let date: String?
    let mode: String
    let title: String?
    let content: String
    let createdAt: String
    let updatedAt: String
}

enum ReportPresentationBuilder {
    static func groups(
        from reports: [ReportPresentationInput],
        today: String
    ) -> [ReportDateGroup] {
        let sortedReports = reports.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.id > $1.id
            }
            return $0.updatedAt > $1.updatedAt
        }
        let latestID = sortedReports.first?.id
        let items = sortedReports.map { report in
            ReportListItem(
                id: report.id,
                dateText: dateText(for: report),
                mode: ReportMode(apiValue: report.mode),
                title: clean(report.title) ?? "제목 없음",
                preview: preview(report.content),
                createdAtText: ReportDisplayDateFormatter.display(
                    report.createdAt
                ),
                updatedAtText: ReportDisplayDateFormatter.display(
                    report.updatedAt
                ),
                updatedAtSortKey: report.updatedAt,
                isLatest: report.id == latestID
            )
        }
        let grouped = Dictionary(grouping: items, by: \.dateText)

        return grouped.keys.sorted(by: >).compactMap { date in
            guard let reports = grouped[date]?.sorted(by: {
                if $0.updatedAtSortKey == $1.updatedAtSortKey {
                    return $0.id > $1.id
                }
                return $0.updatedAtSortKey > $1.updatedAtSortKey
            }) else {
                return nil
            }
            let isToday = date == today
            return ReportDateGroup(
                id: date,
                title: isToday ? "오늘 · \(date)" : date,
                dateText: date,
                isToday: isToday,
                reports: reports
            )
        }
    }

    static func preview(_ content: String, maxLength: Int = 140) -> String {
        let compact = content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard compact.count > maxLength else {
            return compact
        }

        let endIndex = compact.index(compact.startIndex, offsetBy: maxLength)
        return String(compact[..<endIndex]) + "..."
    }

    static func defaultPDFFileName(
        date: String?,
        mode: ReportMode
    ) -> String {
        let datePart = clean(date) ?? "unknown-date"
        return "Mwoham_Report_\(datePart)_\(mode.apiValue).pdf"
    }

    private static func dateText(for report: ReportPresentationInput) -> String {
        if let date = clean(report.date) {
            return date
        }
        return String(report.createdAt.prefix(10))
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ReportDisplayDateFormatter {
    static func display(_ value: String) -> String {
        guard let date = parse(value) else {
            return value
        }
        return formatter.string(from: date)
    }

    private static func parse(_ value: String) -> Date? {
        if let date = isoWithFractionalSeconds.date(from: value) {
            return date
        }
        return iso.date(from: value)
    }

    private static let isoWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
