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
    private let minimumOCRConfidence: Float = 0.55
    private let maximumSpecialCharacterRatio = 0.55
    private let minimumMeaningfulCharacterCount = 12
    private let maximumOCRTextLength = 4_000
    private var pollingTask: Task<Void, Never>?
    private var lastFrameHash: String?

    init(localApiClient: LocalApiClient, pollingInterval: TimeInterval = 10) {
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

            let recognizedLines = try await recognizeText(in: image)
            guard !recognizedLines.isEmpty else {
                onStatusChange("OCR 품질 낮음")
                return
            }

            let normalizedText = normalizeOCRText(recognizedLines.map(\.text))
            guard hasMeaningfulText(normalizedText) else {
                onStatusChange("OCR 텍스트 부족")
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
            onStatusChange("OCR 저장됨")
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

    private func recognizeText(in image: CGImage) async throws -> [OCRLineCandidate] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { observation -> OCRLineCandidate? in
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= self.minimumOCRConfidence else {
                        return nil
                    }

                    return OCRLineCandidate(text: candidate.string, confidence: candidate.confidence)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
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

    private func normalizeOCRText(_ lines: [String]) -> String {
        var seenLines = Set<String>()
        var normalizedLines: [String] = []

        for rawLine in lines.flatMap({ $0.components(separatedBy: .newlines) }) {
            let line = normalizeWhitespace(rawLine)

            guard !line.isEmpty,
                  !line.contains("￿"),
                  line.count > 2,
                  specialCharacterRatio(in: line) <= maximumSpecialCharacterRatio,
                  !seenLines.contains(line) else {
                continue
            }

            seenLines.insert(line)
            normalizedLines.append(line)
        }

        return limitedText(from: normalizedLines)
    }

    private func normalizeWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func specialCharacterRatio(in text: String) -> Double {
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !scalars.isEmpty else {
            return 1
        }

        let specialCount = scalars.filter { scalar in
            !scalar.properties.isAlphabetic && !CharacterSet.decimalDigits.contains(scalar)
        }.count

        return Double(specialCount) / Double(scalars.count)
    }

    private func limitedText(from lines: [String]) -> String {
        var result = ""

        for line in lines {
            let separator = result.isEmpty ? "" : "\n"
            let nextText = result + separator + line

            if nextText.count > maximumOCRTextLength {
                let remainingCount = maximumOCRTextLength - result.count - separator.count
                if remainingCount > 0 {
                    result += separator + line.prefix(remainingCount)
                }
                break
            }

            result = nextText
        }

        return result
    }

    private func hasMeaningfulText(_ text: String) -> Bool {
        let meaningfulCharacterCount = text.unicodeScalars.filter {
            $0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0)
        }.count
        return meaningfulCharacterCount >= minimumMeaningfulCharacterCount
    }

    private func hashText(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func detectKeywords(in text: String) -> [String]? {
        let keywordCandidates = [
            "error",
            "exception",
            "pytest",
            "ruff",
            "alembic",
            "migration",
            "api",
            "gemini",
            "xcode",
            "swift",
            "fastapi"
        ]
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

private struct OCRLineCandidate {
    let text: String
    let confidence: Float
}

private enum OCRError: Error {
    case captureUnavailable
}
