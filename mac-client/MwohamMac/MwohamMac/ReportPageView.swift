//
//  ReportPageView.swift
//  MwohamMac
//

import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers

struct ReportPageView: View {
    @ObservedObject var viewModel: ReportViewModel
    let isBackendConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if !isBackendConnected {
                ErrorBanner(
                    message: "백엔드에 연결할 수 없어 리포트를 불러오거나 저장할 수 없습니다.",
                    title: "백엔드 연결 실패"
                )
            }

            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage, title: "리포트 처리 실패")
            }

            reportListCard
        }
        .task {
            if !viewModel.hasReports {
                await viewModel.refresh()
            }
        }
        .sheet(item: $viewModel.presentedReport) { report in
            ReportDetailSheet(viewModel: viewModel, report: report)
                .frame(minWidth: 760, minHeight: 680)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("리포트")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("날짜별 리포트를 확인하고 Markdown을 편집하거나 PDF로 내보냅니다.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                PrimaryActionButton(
                    title: "리포트 새로고침",
                    systemImage: "arrow.clockwise",
                    isDisabled: viewModel.isLoading
                ) {
                    await viewModel.refresh()
                }

                HStack(spacing: 8) {
                    PrimaryActionButton(
                        title: "간단 생성",
                        systemImage: "doc.text",
                        isDisabled: viewModel.creatingMode != nil
                    ) {
                        await viewModel.create(mode: .simple)
                    }

                    PrimaryActionButton(
                        title: "상세 생성",
                        systemImage: "doc.text.magnifyingglass",
                        isDisabled: viewModel.creatingMode != nil
                    ) {
                        await viewModel.create(mode: .detailed)
                    }
                }
            }
        }
    }

    private var reportListCard: some View {
        StatusCard("리포트 목록", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.isLoading {
                    ProgressView("리포트를 불러오는 중")
                }

                if viewModel.groups.isEmpty && !viewModel.isLoading {
                    EmptyStateView(
                        title: "리포트 없음",
                        message: "간단 리포트 생성 또는 상세 리포트 생성을 눌러 리포트를 만들 수 있습니다.",
                        systemImage: "doc.badge.plus"
                    )
                } else {
                    ForEach(viewModel.groups) { group in
                        ReportDateGroupView(group: group, viewModel: viewModel)
                    }
                }
            }
        }
    }
}

private struct ReportDateGroupView: View {
    let group: ReportDateGroup
    @ObservedObject var viewModel: ReportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.title)
                    .font(.headline)
                Spacer()
                Text("\(group.reports.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(group.reports) { item in
                ReportCard(
                    item: item,
                    isSelected: item.id == viewModel.presentedReport?.id
                ) {
                    if let report = viewModel.report(id: item.id) {
                        viewModel.present(report)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ReportCard: View {
    let item: ReportListItem
    let isSelected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                StatusBadge(state: item.mode, compact: true)
                StatusBadge(state: item.creator, compact: true)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        if item.isLatest {
                            Text("최신")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.1), in: Capsule())
                        }
                    }

                    Text(item.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Text("생성 \(item.createdAtText)")
                        Text("수정 \(item.updatedAtText)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(10)
            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("리포트 상세 열기")
    }
}

private struct ReportDetailSheet: View {
    @ObservedObject var viewModel: ReportViewModel
    let report: ReportResponse
    @Environment(\.dismiss) private var dismiss
    @State private var exportMessage: String?
    @State private var exportErrorMessage: String?
    @State private var isExportingPDF = false

    private var currentReport: ReportResponse {
        viewModel.presentedReport ?? report
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(message: errorMessage, title: "리포트 처리 실패")
            }

            if let exportErrorMessage {
                ErrorBanner(message: exportErrorMessage, title: "PDF 내보내기 실패")
            }

            if let copyMessage = viewModel.copyMessage {
                Text(copyMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if viewModel.hasUnsavedChanges {
                WarningBanner(
                    message: "저장하지 않은 변경사항이 있습니다.",
                    title: "편집 중"
                )
            }

            if currentReport.createdBy == "fallback" {
                WarningBanner(
                    message: fallbackReasonText(currentReport.fallbackReason),
                    title: "Fallback 리포트"
                )
            }

            if viewModel.isEditing {
                editor
            } else {
                markdownPreview
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentReport.title ?? "제목 없음")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(metaText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusBadge(
                    state: ReportMode(apiValue: currentReport.mode),
                    compact: true
                )
                StatusBadge(
                    state: ReportCreator(apiValue: currentReport.createdBy),
                    compact: true
                )
            }

            HStack(spacing: 8) {
                if viewModel.isEditing {
                    PrimaryActionButton(
                        title: "저장",
                        systemImage: "square.and.arrow.down",
                        isDisabled: !viewModel.canSave
                    ) {
                        await viewModel.save()
                    }

                    PrimaryActionButton(
                        title: "취소",
                        systemImage: "xmark.circle",
                        isDisabled: viewModel.isSaving
                    ) {
                        viewModel.cancelEditing()
                    }
                } else {
                    PrimaryActionButton(
                        title: "편집",
                        systemImage: "pencil"
                    ) {
                        viewModel.beginEditing()
                    }

                    PrimaryActionButton(
                        title: "전체 복사",
                        systemImage: "doc.on.doc"
                    ) {
                        copyMarkdown()
                    }

                    PrimaryActionButton(
                        title: "PDF 내보내기",
                        systemImage: "square.and.arrow.up",
                        isDisabled: isExportingPDF
                    ) {
                        exportPDF()
                    }
                }

                Spacer()

                Button {
                    viewModel.closePresentedReport()
                    dismiss()
                } label: {
                    Label("닫기", systemImage: "xmark.circle")
                }
                .accessibilityLabel("리포트 상세 닫기")
            }
        }
    }

    private var metaText: String {
        [
            currentReport.date.map { "날짜 \($0)" },
            "생성 \(ReportDisplayDateFormatter.display(currentReport.createdAt))",
            "수정 \(ReportDisplayDateFormatter.display(currentReport.updatedAt))",
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func fallbackReasonText(_ reason: String?) -> String {
        switch reason {
        case "api_key_missing":
            return "AI Provider 키가 적용되지 않아 로컬 fallback 리포트로 생성되었습니다."
        case "invalid_api_key":
            return "AI Provider 인증에 실패해 로컬 fallback 리포트로 생성되었습니다."
        case "quota_exceeded":
            return "AI Provider 사용량 제한으로 로컬 fallback 리포트로 생성되었습니다."
        case "timeout":
            return "AI 호출이 지연되어 로컬 fallback 리포트로 생성되었습니다."
        case "network_error":
            return "AI Provider 네트워크 호출에 실패해 로컬 fallback 리포트로 생성되었습니다."
        default:
            return "AI 응답을 사용할 수 없어 로컬 fallback 리포트로 생성되었습니다."
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $viewModel.draftContent)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 440)
                .border(.secondary.opacity(0.25))
                .accessibilityLabel("리포트 Markdown 편집")

            Text("저장 실패 시 현재 편집 내용은 유지됩니다. 취소하면 마지막 저장본으로 돌아갑니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var markdownPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Markdown 원문")
                .font(.subheadline)
                .fontWeight(.semibold)

            ScrollView {
                Text(currentReport.content)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 440)
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentReport.content, forType: .string)
        viewModel.markCopied("전체 Markdown")
        exportMessage = nil
        exportErrorMessage = nil
    }

    private func exportPDF() {
        isExportingPDF = true
        exportMessage = nil
        exportErrorMessage = nil
        defer {
            isExportingPDF = false
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ReportPresentationBuilder
            .defaultPDFFileName(
                date: currentReport.date,
                mode: ReportMode(apiValue: currentReport.mode)
            )

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let data = try ReportPDFExporter.makePDFData(report: currentReport)
            try data.write(to: url, options: .atomic)
            exportMessage = "PDF 저장 완료: \(url.lastPathComponent)"
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }
}

private enum ReportPDFExporter {
    enum ExportError: LocalizedError {
        case cannotCreateContext

        var errorDescription: String? {
            switch self {
            case .cannotCreateContext:
                return "PDF context를 만들 수 없습니다."
            }
        }
    }

    static func makePDFData(report: ReportResponse) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw ExportError.cannotCreateContext
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            throw ExportError.cannotCreateContext
        }

        let attributedText = attributedPDFText(for: report)
        let textLength = attributedText.length
        let framesetter = CTFramesetterCreateWithAttributedString(
            attributedText as CFAttributedString
        )
        var currentRange = CFRange(location: 0, length: 0)
        let pageRect = CGRect(x: 54, y: 54, width: 487, height: 734)

        repeat {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.translateBy(x: 0, y: mediaBox.height)
            context.scaleBy(x: 1, y: -1)

            let path = CGMutablePath()
            path.addRect(pageRect)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                currentRange,
                path,
                nil
            )
            CTFrameDraw(frame, context)

            let visibleRange = CTFrameGetVisibleStringRange(frame)
            currentRange.location += visibleRange.length
            context.endPDFPage()
        } while currentRange.location < textLength

        context.closePDF()
        return data as Data
    }

    private static func attributedPDFText(
        for report: ReportResponse
    ) -> NSMutableAttributedString {
        let title = report.title ?? "Mwoham Report"
        let mode = ReportMode(apiValue: report.mode).label
        let date = report.date ?? "날짜 없음"
        let header = "\(title)\n\(mode) · \(date)\n\n"
        let fullText = header + report.content

        let attributed = NSMutableAttributedString(string: fullText)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
            ],
            range: fullRange
        )

        let headerRange = NSRange(location: 0, length: header.count)
        attributed.addAttributes(
            [
                .font: NSFont.boldSystemFont(ofSize: 16),
                .foregroundColor: NSColor.labelColor,
            ],
            range: headerRange
        )

        return attributed
    }
}
