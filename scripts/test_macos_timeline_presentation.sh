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

func item(
    _ id: String,
    hour: Int,
    minute: Int = 0,
    category: TimelineEventCategory,
    title: String,
    duration: Int? = nil,
    important: Bool = false,
    appName: String? = nil,
    windowTitle: String? = nil
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
        isImportant: important,
        isFoldedNoise: false,
        noiseReason: nil,
        detailLines: []
    )
}

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
