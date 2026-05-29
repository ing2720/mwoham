//
//  OCRCollector.swift
//  MwohamMac
//

import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ScreenCaptureKit
import Vision

@MainActor
final class OCRCollector {
    private let localApiClient: LocalApiClient
    private let pollingInterval: TimeInterval
    private var pollingTask: Task<Void, Never>?
    private var lastFrameHash: String?

    init(localApiClient: LocalApiClient, pollingInterval: TimeInterval = 15) {
        self.localApiClient = localApiClient
        self.pollingInterval = pollingInterval
    }

    func start(
        isRecordingActive: @escaping @MainActor () -> Bool,
        isPrivateAppActive: @escaping @MainActor () -> Bool,
        currentApp: @escaping @MainActor () -> String,
        currentWindow: @escaping @MainActor () -> String,
        onStatusChange: @escaping @MainActor (String) -> Void
    ) {
        guard pollingTask == nil else {
            return
        }

        onStatusChange("OCR 대기 중")

        pollingTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                await collectIfNeeded(
                    isRecordingActive: isRecordingActive,
                    isPrivateAppActive: isPrivateAppActive,
                    currentApp: currentApp,
                    currentWindow: currentWindow,
                    onStatusChange: onStatusChange
                )

                do {
                    try await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        lastFrameHash = nil
    }

    private func collectIfNeeded(
        isRecordingActive: @escaping @MainActor () -> Bool,
        isPrivateAppActive: @escaping @MainActor () -> Bool,
        currentApp: @escaping @MainActor () -> String,
        currentWindow: @escaping @MainActor () -> String,
        onStatusChange: @escaping @MainActor (String) -> Void
    ) async {
        guard isRecordingActive() else {
            onStatusChange("OCR 대기 중")
            return
        }

        guard !isPrivateAppActive() else {
            onStatusChange("비공개 앱으로 OCR 중지")
            return
        }

        guard !isOwnApplicationActive() else {
            onStatusChange("OCR 대기 중")
            return
        }

        guard hasScreenCaptureAccess() else {
            onStatusChange("권한 필요")
            return
        }

        onStatusChange("OCR 수집 중")

        do {
            let image = try await captureScreenImage()

            let ocrText = try await recognizeText(in: image)
            let normalizedText = normalizeOCRText(ocrText)
            guard !normalizedText.isEmpty else {
                onStatusChange("OCR 대기 중")
                return
            }

            let frameHash = hashText(normalizedText)
            guard frameHash != lastFrameHash else {
                onStatusChange("OCR 대기 중")
                return
            }

            try await localApiClient.createScreenObservation(
                appName: sanitizedContextValue(currentApp()),
                windowTitle: sanitizedContextValue(currentWindow()),
                ocrText: normalizedText,
                detectedKeywords: detectKeywords(in: normalizedText),
                aiInference: nil,
                frameHash: frameHash
            )
            lastFrameHash = frameHash
            onStatusChange("OCR 대기 중")
        } catch {
            onStatusChange("OCR 오류")
        }
    }

    private func hasScreenCaptureAccess() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }

        return true
    }

    private func captureScreenImage() async throws -> CGImage {
        let content = try await SCShareableContent.current
        let display = content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first

        guard let display else {
            throw OCRError.captureUnavailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width * 2
        configuration.height = display.height * 2
        configuration.showsCursor = false
        configuration.capturesAudio = false

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image else {
                    continuation.resume(throwing: OCRError.captureUnavailable)
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }

    private func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ko-KR", "en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func normalizeOCRText(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func hashText(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func detectKeywords(in text: String) -> [String]? {
        let keywordCandidates = ["error", "failed", "exception", "token", "api", "오류", "실패", "인증"]
        let loweredText = text.lowercased()
        let keywords = keywordCandidates.filter { loweredText.contains($0.lowercased()) }
        return keywords.isEmpty ? nil : keywords
    }

    private func sanitizedContextValue(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty || trimmedValue == "없음" || trimmedValue.hasPrefix("비공개") {
            return nil
        }

        return trimmedValue
    }

    private func isOwnApplicationActive() -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let ownName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        let ownDisplayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let activeName = application.localizedName ?? application.bundleIdentifier ?? ""
        let candidates = [ownName, ownDisplayName, "MwohamMac", "Mwoham"].compactMap { $0 }
        return candidates.contains(activeName)
    }
}

private enum OCRError: Error {
    case captureUnavailable
}
