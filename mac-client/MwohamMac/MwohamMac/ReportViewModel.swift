//
//  ReportViewModel.swift
//  MwohamMac
//

import Combine
import Foundation

@MainActor
final class ReportViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var creatingMode: ReportMode?
    @Published private(set) var errorMessage: String?
    @Published private(set) var reports: [ReportResponse] = []
    @Published private(set) var groups: [ReportDateGroup] = []
    @Published var presentedReport: ReportResponse?
    @Published var draftContent = ""
    @Published var isEditing = false
    @Published private(set) var copyMessage: String?

    private let localApiClient: LocalApiClient
    private var lastSavedContent = ""

    var hasReports: Bool {
        !reports.isEmpty
    }

    var hasUnsavedChanges: Bool {
        isEditing && draftContent != lastSavedContent
    }

    var canSave: Bool {
        hasUnsavedChanges
            && !draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            && !isSaving
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
            let response = try await localApiClient.fetchReports(limit: 100)
            reports = response.items
            rebuildGroups()
            if let presentedReport,
               let refreshed = report(id: presentedReport.id) {
                present(refreshed)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func present(_ report: ReportResponse) {
        presentedReport = report
        isEditing = false
        copyMessage = nil
        draftContent = report.content
        lastSavedContent = report.content
    }

    func closePresentedReport() {
        presentedReport = nil
        isEditing = false
        copyMessage = nil
        draftContent = ""
        lastSavedContent = ""
    }

    func create(mode: ReportMode) async {
        guard creatingMode == nil else {
            return
        }

        creatingMode = mode
        errorMessage = nil

        do {
            let created = try await localApiClient.createDailyReport(
                mode: mode.apiValue
            )
            upsert(created)
            present(created)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }

        creatingMode = nil
    }

    func beginEditing() {
        guard presentedReport != nil else {
            return
        }
        isEditing = true
        copyMessage = nil
    }

    func cancelEditing() {
        draftContent = lastSavedContent
        isEditing = false
        copyMessage = nil
    }

    func save() async {
        guard let presentedReport, canSave else {
            return
        }

        isSaving = true
        errorMessage = nil

        do {
            let updated = try await localApiClient.updateReport(
                id: presentedReport.id,
                content: draftContent
            )
            upsert(updated)
            present(updated)
        } catch {
            errorMessage = error.localizedDescription
        }

        isSaving = false
    }

    func markCopied(_ label: String) {
        copyMessage = "\(label) 복사됨"
    }

    func clearTransientMessages() {
        copyMessage = nil
    }

    private func upsert(_ report: ReportResponse) {
        if let index = reports.firstIndex(where: { $0.id == report.id }) {
            reports[index] = report
        } else {
            reports.insert(report, at: 0)
        }
        reports.sort {
            if $0.updatedAt == $1.updatedAt {
                return $0.id > $1.id
            }
            return $0.updatedAt > $1.updatedAt
        }
        rebuildGroups()
    }

    private func rebuildGroups() {
        groups = ReportPresentationBuilder.groups(
            from: reports.map {
                ReportPresentationInput(
                    id: $0.id,
                    date: $0.date,
                    mode: $0.mode,
                    title: $0.title,
                    content: $0.content,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            },
            today: Self.todayText
        )
    }

    func report(id: Int) -> ReportResponse? {
        reports.first { $0.id == id }
    }

    private static let todayText: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }()
}
