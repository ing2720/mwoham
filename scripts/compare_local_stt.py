#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn

REPO_ROOT = Path(__file__).resolve().parents[1]
APPLE_SPEECH_SOURCE = REPO_ROOT / "scripts" / "apple_speech_file_transcriber.swift"


class PocError(RuntimeError):
    pass


@dataclass(frozen=True)
class TranscriptionResult:
    transcript: str
    processing_seconds: float


def fail(message: str) -> NoReturn:
    raise PocError(message)


def resolved_file(path_value: str, *, label: str) -> Path:
    path = Path(path_value).expanduser().resolve()
    if not path.is_file():
        fail(f"{label} file not found: {path}")
    return path


def ensure_outside_repo(path: Path, *, label: str) -> None:
    try:
        path.relative_to(REPO_ROOT)
    except ValueError:
        return
    fail(f"{label} must be outside the repository: {path}")


def resolve_executable(path_value: str | None) -> Path:
    if path_value:
        executable = resolved_file(path_value, label="Whisper executable")
    else:
        discovered = shutil.which("whisper-cli")
        if discovered is None:
            fail("whisper-cli not found. Pass its path with --whisper-bin.")
        executable = Path(discovered).resolve()

    if not os.access(executable, os.X_OK):
        fail(f"Whisper executable is not executable: {executable}")
    return executable


def run_command(
    command: list[str],
    *,
    timeout: float,
    label: str,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        fail(f"{label} timed out after {timeout:.0f} seconds: {error.cmd}")
    except OSError as error:
        fail(f"{label} could not start: {error}")


def normalize_wav(input_path: Path, output_path: Path, *, timeout: float) -> None:
    afconvert = shutil.which("afconvert")
    if afconvert is None:
        fail("afconvert not found. This POC requires macOS.")

    completed = run_command(
        [
            afconvert,
            str(input_path),
            str(output_path),
            "-f",
            "WAVE",
            "-d",
            "LEI16@16000",
            "-c",
            "1",
        ],
        timeout=timeout,
        label="WAV normalization",
    )
    if completed.returncode != 0 or not output_path.is_file():
        details = completed.stderr.strip() or completed.stdout.strip() or "unknown error"
        fail(f"WAV normalization failed: {details}")


def write_helper_info_plist(plist_path: Path, executable_name: str) -> None:
    payload = {
        "CFBundleExecutable": executable_name,
        "CFBundleIdentifier": "com.ing2720.MwohamAppleSpeechPOC",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Mwoham Apple Speech POC",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSUIElement": True,
        "NSSpeechRecognitionUsageDescription": (
            "로컬 STT 품질 비교를 위해 사용자가 지정한 WAV 파일을 Apple Speech로 전사합니다."
        ),
    }
    with plist_path.open("wb") as plist_file:
        plistlib.dump(payload, plist_file)


def build_apple_speech_helper(work_dir: Path, *, timeout: float) -> Path:
    xcrun = shutil.which("xcrun")
    codesign = shutil.which("codesign")
    if xcrun is None or codesign is None:
        fail("xcrun and codesign are required. Install full Xcode.")

    app_dir = work_dir / "MwohamAppleSpeechPOC.app"
    contents_dir = app_dir / "Contents"
    executable_dir = contents_dir / "MacOS"
    executable_dir.mkdir(parents=True)
    executable_name = "MwohamAppleSpeechPOC"
    executable_path = executable_dir / executable_name
    write_helper_info_plist(contents_dir / "Info.plist", executable_name)

    compiled = run_command(
        [
            xcrun,
            "swiftc",
            "-parse-as-library",
            "-swift-version",
            "5",
            "-O",
            "-module-cache-path",
            str(work_dir / "SwiftModuleCache"),
            str(APPLE_SPEECH_SOURCE),
            "-o",
            str(executable_path),
            "-framework",
            "Foundation",
            "-framework",
            "Speech",
        ],
        timeout=timeout,
        label="Apple Speech helper compilation",
    )
    if compiled.returncode != 0:
        details = compiled.stderr.strip() or compiled.stdout.strip() or "unknown error"
        fail(f"Apple Speech helper compilation failed: {details}")

    signed = run_command(
        [codesign, "--force", "--sign", "-", str(app_dir)],
        timeout=timeout,
        label="Apple Speech helper signing",
    )
    if signed.returncode != 0:
        details = signed.stderr.strip() or signed.stdout.strip() or "unknown error"
        fail(f"Apple Speech helper signing failed: {details}")
    return executable_path


def transcribe_with_apple_speech(
    helper_path: Path,
    wav_path: Path,
    *,
    locale: str,
    timeout: float,
) -> TranscriptionResult:
    completed = run_command(
        [str(helper_path), str(wav_path), locale, str(timeout)],
        timeout=timeout + 5,
        label="Apple Speech",
    )
    if completed.returncode != 0:
        details = completed.stderr.strip() or completed.stdout.strip() or "unknown error"
        fail(f"Apple Speech failed: {details}")

    try:
        payload = json.loads(completed.stdout)
        transcript = str(payload["transcript"]).strip()
        processing_seconds = float(payload["processing_seconds"])
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        fail(f"Apple Speech returned an invalid result: {error}")
    if not transcript:
        fail("Apple Speech returned an empty transcript.")
    return TranscriptionResult(transcript, processing_seconds)


def transcribe_with_whisper(
    whisper_bin: Path,
    model_path: Path,
    wav_path: Path,
    output_base: Path,
    *,
    language: str,
    timeout: float,
) -> TranscriptionResult:
    output_text_path = output_base.with_suffix(".txt")
    command = [
        str(whisper_bin),
        "-m",
        str(model_path),
        "-f",
        str(wav_path),
        "-l",
        language,
        "-otxt",
        "-of",
        str(output_base),
        "-np",
    ]
    started_at = time.perf_counter()
    completed = run_command(command, timeout=timeout, label="Whisper")
    processing_seconds = time.perf_counter() - started_at

    if completed.returncode != 0:
        details = completed.stderr.strip() or completed.stdout.strip() or "unknown error"
        fail(f"Whisper failed: {details}")
    if not output_text_path.is_file():
        fail(f"Whisper did not create its temporary text output: {output_text_path}")

    transcript = output_text_path.read_text(encoding="utf-8").strip()
    if not transcript:
        fail("Whisper returned an empty transcript.")
    return TranscriptionResult(transcript, processing_seconds)


def print_result(label: str, result: TranscriptionResult) -> None:
    print(f"[{label}]")
    print(f"transcript: {result.transcript}")
    print(f"processing_seconds: {result.processing_seconds:.3f}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare Apple Speech and local whisper.cpp using the same Korean WAV."
    )
    parser.add_argument("--input", required=True, help="WAV file outside this repository")
    parser.add_argument(
        "--model",
        required=True,
        help="whisper.cpp model file outside this repository",
    )
    parser.add_argument("--whisper-bin", help="path to whisper-cli; defaults to PATH lookup")
    parser.add_argument("--language", default="ko", help="Whisper language code (default: ko)")
    parser.add_argument(
        "--apple-locale",
        default="ko-KR",
        help="Apple Speech locale (default: ko-KR)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=180,
        help="per-step timeout in seconds (default: 180)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.timeout <= 0:
        fail("--timeout must be greater than zero.")

    input_path = resolved_file(args.input, label="Input WAV")
    if input_path.suffix.lower() != ".wav":
        fail(f"Input must be a WAV file: {input_path}")
    ensure_outside_repo(input_path, label="Input audio")

    model_path = resolved_file(args.model, label="Whisper model")
    ensure_outside_repo(model_path, label="Whisper model")
    whisper_bin = resolve_executable(args.whisper_bin)

    with tempfile.TemporaryDirectory(prefix="mwoham-stt-poc-") as temp_dir_value:
        temp_dir = Path(temp_dir_value)
        normalized_wav = temp_dir / "input-16khz-mono.wav"
        normalize_wav(input_path, normalized_wav, timeout=args.timeout)

        helper_path = build_apple_speech_helper(temp_dir, timeout=args.timeout)
        apple_result = transcribe_with_apple_speech(
            helper_path,
            normalized_wav,
            locale=args.apple_locale,
            timeout=args.timeout,
        )
        whisper_result = transcribe_with_whisper(
            whisper_bin,
            model_path,
            normalized_wav,
            temp_dir / "whisper-result",
            language=args.language,
            timeout=args.timeout,
        )

        print_result("Apple Speech", apple_result)
        print()
        print_result("Whisper", whisper_result)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PocError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from None
