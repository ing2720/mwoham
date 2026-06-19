//
//  TimelinePageView.swift
//  MwohamMac
//

import SwiftUI

struct TimelinePageView: View {
    @ObservedObject var viewModel: TimelineViewModel
    let isBackendConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if !isBackendConnected {
                ErrorBanner(
                    message: "백엔드에 연결할 수 없어 오늘 타임라인을 불러오지 못했습니다.",
                    title: "백엔드 연결 실패"
                )
            }

            filterPicker

            if viewModel.isLoading {
                ProgressView("타임라인을 불러오는 중")
            }

            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(
                    message: errorMessage,
                    title: "타임라인 로딩 실패"
                )
            }

            timelineContent
        }
        .task {
            if !viewModel.hasLoadedItems {
                await viewModel.refresh()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("타임라인")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("오늘의 앱 활동, 메모, 회의 전사, 개발 이벤트를 시간대별로 봅니다.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text(viewModel.responseDateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                PrimaryActionButton(
                    title: "타임라인 새로고침",
                    systemImage: "arrow.clockwise",
                    isDisabled: viewModel.isLoading
                ) {
                    await viewModel.refresh()
                }
            }
        }
    }

    private var filterPicker: some View {
        Picker("필터", selection: $viewModel.selectedFilter) {
            ForEach(TimelineFilter.allCases) { filter in
                Label(filter.label, systemImage: filter.systemImage)
                    .tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("타임라인 필터")
    }

    @ViewBuilder
    private var timelineContent: some View {
        if !viewModel.isLoading
            && viewModel.errorMessage == nil
            && !viewModel.hasLoadedItems {
            EmptyStateView(
                title: "오늘 기록 없음",
                message: "기록을 시작하거나 메모, 회의 전사를 추가하면 타임라인에 표시됩니다.",
                systemImage: "calendar.badge.exclamationmark"
            )
        } else if !viewModel.isLoading
            && viewModel.errorMessage == nil
            && viewModel.hasLoadedItems
            && !viewModel.hasFilterResults {
            EmptyStateView(
                title: "필터 결과 없음",
                message: "선택한 필터에 해당하는 타임라인 항목이 없습니다.",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(viewModel.groups) { group in
                    TimelineGroupCard(group: group)
                }
            }
        }
    }
}

private struct TimelineGroupCard: View {
    let group: TimelineDisplayGroup

    var body: some View {
        StatusCard(group.title, systemImage: group.systemImage) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label("\(group.totalCount)개", systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if group.importantCount > 0 {
                        Label("\(group.importantCount)개 중요", systemImage: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if group.isReportCandidate {
                        Text("리포트 후보")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.1), in: Capsule())
                    }

                    Spacer()
                }

                if group.items.isEmpty {
                    Text("이 시간대는 접힌 보조 이벤트만 있습니다. 접힌 이벤트를 열어 세부 흐름을 확인하세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(group.items) { item in
                        TimelineEventCard(item: item)
                    }
                }

                if !group.foldedItems.isEmpty {
                    DisclosureGroup("접힌 이벤트 \(group.foldedItems.count)개") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(group.foldedItems) { item in
                                TimelineEventCard(item: item, compact: true)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
    }
}

private struct TimelineEventCard: View {
    let item: TimelineDisplayItem
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.timeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)

                StatusBadge(state: item.category, compact: true)

                if item.isImportant {
                    Label("중요", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let noiseReason = item.noiseReason {
                    Text(noiseReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(compact ? .callout : .headline)
                    .lineLimit(compact ? 1 : 2)

                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 2 : 4)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    if let sourceText = item.sourceText {
                        Label(sourceText, systemImage: "tag")
                    }
                    if let durationText = item.durationText {
                        Label(durationText, systemImage: "clock")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.leading, 52)

            if !compact && !item.detailLines.isEmpty {
                DisclosureGroup("상세 보기") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(item.detailLines, id: \.self) { line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.leading, 52)
            }
        }
        .padding(10)
        .background(
            compact
                ? Color.secondary.opacity(0.06)
                : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .combine)
    }
}
