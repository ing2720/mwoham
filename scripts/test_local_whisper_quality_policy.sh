#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="$ROOT_DIR/mac-client/MwohamMac/MwohamMac/LocalWhisperMeetingTranscriber.swift"
WORK_DIR="$(mktemp -d /private/tmp/mwoham-whisper-quality.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

cp "$SOURCE_FILE" "$WORK_DIR/LocalWhisperMeetingTranscriber.swift"
cat > "$WORK_DIR/main.swift" <<'SWIFT'
import Foundation

protocol SpeechTranscriptionProvider {}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("failed: \(message)\n", stderr)
        exit(1)
    }
}

let subtitleAd = LocalWhisperTranscriptQualityPolicy.evaluate(
    "자막 제공 및 자막 제공 및 광고를 포함하고 있습니다."
)
expect(
    subtitleAd.rejectionReason == "subtitle_ad_hallucination",
    "subtitle/ad hallucination should reject"
)

let byline = LocalWhisperTranscriptQualityPolicy.evaluate(
    "한글자막 by 한글자막 by 한효정"
)
expect(
    byline.rejectionReason == "subtitle_ad_hallucination",
    "subtitle byline hallucination should reject"
)

let leading = LocalWhisperTranscriptQualityPolicy.evaluate(
    "자막 제공. 오늘 회의에서는 검색 품질 개선을 논의했습니다."
)
expect(
    leading.acceptedText == "오늘 회의에서는 검색 품질 개선을 논의했습니다",
    "leading subtitle sentence should be removed"
)

let trailing = LocalWhisperTranscriptQualityPolicy.evaluate(
    "오늘 회의에서는 검색 품질 개선을 논의했습니다. subtitles by example"
)
expect(
    trailing.acceptedText == "오늘 회의에서는 검색 품질 개선을 논의했습니다",
    "trailing subtitles by sentence should be removed"
)

let realMeetingSentence = LocalWhisperTranscriptQualityPolicy.evaluate(
    "오늘 회의에서는 자막 제공 기능의 접근성 개선을 논의했습니다"
)
expect(
    realMeetingSentence.acceptedText
        == "오늘 회의에서는 자막 제공 기능의 접근성 개선을 논의했습니다",
    "embedded real meeting sentence should remain"
)

let repeated = LocalWhisperTranscriptQualityPolicy.evaluate(
    "테스트 완료 테스트 완료 테스트 완료 테스트 완료"
)
expect(
    repeated.rejectionReason == "repeated_phrase",
    "existing repeated phrase guard should remain"
)
SWIFT

CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache" swiftc \
    "$WORK_DIR/main.swift" \
    "$WORK_DIR/LocalWhisperMeetingTranscriber.swift" \
    -o "$WORK_DIR/harness"
"$WORK_DIR/harness"
