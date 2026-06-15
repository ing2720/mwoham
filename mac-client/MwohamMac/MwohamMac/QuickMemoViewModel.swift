//
//  QuickMemoViewModel.swift
//  MwohamMac
//

import Combine
import Foundation

@MainActor
final class QuickMemoViewModel: ObservableObject {
    @Published var content = ""
    @Published private(set) var statusMessage = ""
    @Published private(set) var isSaving = false

    private let localApiClient: LocalApiClient
    private var isConnected: () -> Bool = { false }
    private var onSnapshotReceived: (BackendSnapshot) -> Void = { _ in }
    private var onRefreshAfterFailedAction: () async -> Void = {}

    init(localApiClient: LocalApiClient) {
        self.localApiClient = localApiClient
    }

    func configure(
        isConnected: @escaping () -> Bool,
        onSnapshotReceived: @escaping (BackendSnapshot) -> Void,
        onRefreshAfterFailedAction: @escaping () async -> Void
    ) {
        self.isConnected = isConnected
        self.onSnapshotReceived = onSnapshotReceived
        self.onRefreshAfterFailedAction = onRefreshAfterFailedAction
    }

    var canSave: Bool {
        isConnected() && !isSaving
    }

    func save() async {
        guard !isSaving else {
            return
        }

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            statusMessage = "메모 내용을 입력해 주세요."
            return
        }

        isSaving = true
        statusMessage = "메모 저장 중..."

        do {
            try await localApiClient.createMemo(content: trimmedContent)
            content = ""
            statusMessage = "메모가 저장되었습니다."
            onSnapshotReceived(try await localApiClient.fetchSnapshot())
        } catch {
            statusMessage = "메모 저장에 실패했습니다: \(error.localizedDescription)"
            await onRefreshAfterFailedAction()
        }

        isSaving = false
    }
}
