#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_TYPES="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/StatusTypes.swift"
REPORT_PRESENTATION="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/ReportPresentation.swift"
WORK_DIR="$(mktemp -d /private/tmp/mwoham-report-presentation.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("failed: \(message)\n", stderr)
        exit(1)
    }
}

let reports = [
    ReportPresentationInput(
        id: 1,
        date: "2026-06-15",
        mode: "simple",
        title: "어제 간단 리포트",
        content: "어제 작업 요약",
        createdAt: "2026-06-15T09:00:00Z",
        updatedAt: "2026-06-15T09:10:00Z"
    ),
    ReportPresentationInput(
        id: 2,
        date: "2026-06-16",
        mode: "detailed",
        title: "오늘 상세 리포트",
        content: "오늘 작업 요약\n두 번째 줄",
        createdAt: "2026-06-16T10:00:00Z",
        updatedAt: "2026-06-16T10:30:00Z"
    ),
    ReportPresentationInput(
        id: 3,
        date: "2026-06-16",
        mode: "simple",
        title: nil,
        content: String(repeating: "가", count: 160),
        createdAt: "2026-06-16T11:00:00Z",
        updatedAt: "2026-06-16T11:30:00Z"
    ),
]

let groups = ReportPresentationBuilder.groups(from: reports, today: "2026-06-16")
expect(groups.count == 2, "reports are grouped by date")
expect(groups[0].title == "오늘 · 2026-06-16", "today group includes today label")
expect(groups[0].reports.count == 2, "today detailed and simple are in one group")
expect(groups[1].title == "2026-06-15", "older group uses date only")
expect(groups[0].reports[0].id == 3, "latest updated report is first")
expect(groups[0].reports[0].isLatest, "latest report is marked")
expect(groups[0].reports[0].title == "제목 없음", "missing title fallback")
expect(groups[0].reports[0].preview.hasSuffix("..."), "long preview is truncated")
expect(groups[0].reports[1].mode == .detailed, "detailed badge policy is preserved")
expect(groups[1].reports[0].mode == .simple, "simple badge policy is preserved")

let fileName = ReportPresentationBuilder.defaultPDFFileName(
    date: "2026-06-16",
    mode: .simple
)
expect(
    fileName == "Mwoham_Report_2026-06-16_simple.pdf",
    "default PDF filename includes date and mode"
)

expect(ReportMode(apiValue: "detailed").label == "상세 리포트", "detailed mode label")
expect(ReportMode(apiValue: "simple").label == "간단 리포트", "simple mode label")
expect(ReportCreator(apiValue: "ai").label == "AI 생성", "ai creator label")
expect(ReportCreator(apiValue: "user").label == "사용자 수정", "user creator label")

print("macOS report presentation tests passed")
SWIFT

CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache" swiftc \
    "$WORK_DIR/main.swift" \
    "$STATUS_TYPES" \
    "$REPORT_PRESENTATION" \
    -o "$WORK_DIR/harness"
"$WORK_DIR/harness"
