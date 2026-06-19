#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_TYPES="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/StatusTypes.swift"
TIMELINE_PRESENTATION="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/TimelinePresentation.swift"
WORK_DIR="$(mktemp -d /private/tmp/mwoham-timeline-presentation.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("failed: \(message)\n", stderr)
        exit(1)
    }
}

func makeDate(_ hour: Int, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(identifier: "Asia/Seoul")
    components.year = 2026
    components.month = 6
    components.day = 16
    components.hour = hour
    components.minute = minute
    return components.date!
}

func kstComponents(_ date: Date) -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return calendar.dateComponents([.hour, .minute, .second], from: date)
}

func item(
    _ id: String,
    hour: Int,
    minute: Int = 0,
    category: TimelineEventCategory,
    title: String,
    duration: Int? = nil,
    important: Bool = false,
    appName: String? = nil,
    windowTitle: String? = nil,
    hiddenByDefault: Bool = false,
    noiseReason: String? = nil
) -> TimelineDisplayItem {
    TimelineDisplayItem(
        id: id,
        rawType: category.rawValue,
        timestamp: makeDate(hour, minute),
        endedAt: nil,
        category: category,
        title: title,
        description: title,
        sourceText: appName,
        appName: appName,
        windowTitle: windowTitle,
        durationSeconds: duration,
        signalLevel: nil,
        hiddenByDefault: hiddenByDefault,
        eventCount: nil,
        isImportant: important,
        isFoldedNoise: hiddenByDefault,
        noiseReason: noiseReason,
        detailLines: []
    )
}

let backendTimestamp = TimelineDateParser.parse("2026-06-19T00:23:46.506000")
expect(backendTimestamp != nil, "backend fractional timestamp without timezone parses")
let backendComponents = kstComponents(backendTimestamp!)
expect(backendComponents.hour == 9, "backend timestamp is interpreted as UTC and displayed in KST")
expect(backendComponents.minute == 23, "backend timestamp minute is preserved")

let backendWholeSecondTimestamp = TimelineDateParser.parse("2026-06-19T00:21:30")
expect(backendWholeSecondTimestamp != nil, "backend whole-second timestamp without timezone parses")
let backendWholeSecondComponents = kstComponents(backendWholeSecondTimestamp!)
expect(backendWholeSecondComponents.hour == 9, "whole-second backend timestamp uses UTC")
expect(backendWholeSecondComponents.second == 30, "whole-second backend timestamp preserves seconds")

let items = [
    item(
        "activity-short",
        hour: 9,
        category: .appActivity,
        title: "Safari / Search",
        duration: 12,
        appName: "Safari",
        windowTitle: "Search"
    ),
    item(
        "memo",
        hour: 10,
        category: .memo,
        title: "수동 메모",
        important: true
    ),
    item(
        "dev",
        hour: 14,
        category: .dev,
        title: "명령 실패",
        important: true
    ),
    item(
        "activity-long",
        hour: 15,
        category: .appActivity,
        title: "Xcode / Timeline",
        duration: 1800,
        important: true,
        appName: "Xcode",
        windowTitle: "Timeline"
    ),
    item(
        "activity-repeat",
        hour: 15,
        minute: 2,
        category: .appActivity,
        title: "Xcode / Timeline",
        duration: 1800,
        appName: "Xcode",
        windowTitle: "Timeline"
    ),
    item(
        "activity-refined-hidden",
        hour: 15,
        minute: 4,
        category: .appActivity,
        title: "Preview",
        duration: 120,
        appName: "Preview",
        windowTitle: "Untitled"
    ),
    item(
        "meeting",
        hour: 19,
        category: .meeting,
        title: "회의 전사",
        important: true
    ),
]

let allGroups = TimelinePresentationBuilder.groups(for: items, filter: .all)
expect(allGroups.count == 3, "items are grouped into morning, afternoon, evening")
expect(allGroups[0].title == "오전", "morning group is first")
expect(allGroups[1].title == "오후", "afternoon group is second")
expect(allGroups[2].title == "저녁", "evening group is third")
expect(
    allGroups[0].foldedItems.contains { $0.id == "activity-short" },
    "short activity is folded as noise"
)
expect(
    allGroups[1].foldedItems.contains { $0.id == "activity-repeat" },
    "repeated app/window event is folded as noise"
)
expect(allGroups[1].isReportCandidate, "important afternoon group is report candidate")

let refinedHidden = item(
    "activity-refined-backend-hidden",
    hour: 15,
    minute: 6,
    category: .appActivity,
    title: "Finder",
    duration: 120,
    appName: "Finder",
    windowTitle: nil,
    hiddenByDefault: true,
    noiseReason: "의미 약한 창 제목"
)
let refinedGroups = TimelinePresentationBuilder.groups(for: [refinedHidden], filter: .all)
expect(
    refinedGroups[0].items.first?.id == "activity-refined-backend-hidden",
    "hidden-only groups still show a representative activity"
)
expect(
    refinedGroups[0].foldedItems.isEmpty,
    "single hidden-only group does not duplicate the representative activity"
)

let hiddenOnlyItems = [
    refinedHidden,
    item(
        "activity-refined-backend-hidden-2",
        hour: 15,
        minute: 7,
        category: .appActivity,
        title: "Safari",
        duration: 15,
        appName: "Safari",
        hiddenByDefault: true,
        noiseReason: "낮은 신호"
    ),
    item(
        "activity-refined-backend-hidden-3",
        hour: 15,
        minute: 8,
        category: .appActivity,
        title: "Terminal",
        duration: 10,
        appName: "Terminal",
        hiddenByDefault: true,
        noiseReason: "짧은 앱 전환"
    ),
    item(
        "activity-refined-backend-hidden-4",
        hour: 15,
        minute: 9,
        category: .appActivity,
        title: "Finder",
        duration: 8,
        appName: "Finder",
        hiddenByDefault: true,
        noiseReason: "낮은 신호"
    ),
]
let hiddenOnlyGroups = TimelinePresentationBuilder.groups(for: hiddenOnlyItems, filter: .all)
expect(
    hiddenOnlyGroups[0].items.map(\.id) == [
        "activity-refined-backend-hidden",
        "activity-refined-backend-hidden-2",
        "activity-refined-backend-hidden-3",
    ],
    "hidden-only groups promote a chronological preview"
)
expect(
    hiddenOnlyGroups[0].foldedItems.map(\.id) == ["activity-refined-backend-hidden-4"],
    "remaining hidden-only items stay expandable"
)

let memoGroups = TimelinePresentationBuilder.groups(for: items, filter: .memo)
expect(memoGroups.count == 1, "memo filter keeps only memo group")
expect(memoGroups[0].items.first?.category == .memo, "memo filter keeps memo item")

let devGroups = TimelinePresentationBuilder.groups(for: items, filter: .dev)
expect(devGroups.count == 1, "dev filter keeps only dev group")
expect(devGroups[0].items.first?.category == .dev, "dev filter keeps dev item")

let importantGroups = TimelinePresentationBuilder.groups(for: items, filter: .important)
let importantIDs = importantGroups.flatMap { $0.items + $0.foldedItems }.map(\.id)
expect(importantIDs.contains("memo"), "important filter includes memo")
expect(importantIDs.contains("dev"), "important filter includes important dev event")
expect(importantIDs.contains("activity-long"), "important filter includes long activity")
expect(!importantIDs.contains("activity-short"), "important filter removes non-important noise")

print("macOS timeline presentation tests passed")
SWIFT

CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache" swiftc \
    "$WORK_DIR/main.swift" \
    "$STATUS_TYPES" \
    "$TIMELINE_PRESENTATION" \
    -o "$WORK_DIR/harness"
"$WORK_DIR/harness"
