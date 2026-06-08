from __future__ import annotations

import argparse
import json
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

try:
    from scripts._bootstrap import add_backend_root_to_path
except ModuleNotFoundError:
    from _bootstrap import add_backend_root_to_path

add_backend_root_to_path()

from app.services.privacy_filter import get_privacy_filter  # noqa: E402

try:
    from scripts.dev_event_helpers import (
        build_dev_event_request,
        compact_path,
        print_saved_event,
        save_dev_event,
    )
except ModuleNotFoundError:
    from dev_event_helpers import (
        build_dev_event_request,
        compact_path,
        print_saved_event,
        save_dev_event,
    )


MAX_COMMAND_CHARS = 500
IGNORED_COMMANDS = {"cd", "pwd", "ls", "clear"}
HOOK_EXCLUDED_MARKERS = (
    "scripts/record_command_result.py",
    "mwoham_zsh_tracking.zsh",
    "install_command_tracking_hook.py",
    "uninstall_command_tracking_hook.py",
)
ENV_READ_PREFIXES = ("cat", "less", "more", "tail", "head", "sed", "awk", "grep", "rg")


def record_command_result(
    *,
    command: str,
    status: str | None = None,
    summary: str | None = None,
    event_type: str = "command_result",
    exit_code: int | None = None,
    duration_seconds: float | None = None,
    duration_ms: int | None = None,
    cwd: str | None = None,
    repo_path: str | None = None,
    branch: str | None = None,
    started_at: str | None = None,
    ended_at: str | None = None,
    shell: str | None = None,
    source: str = "script",
    session_current: bool = False,
) -> int:
    normalized_command = normalize_command(command)
    if should_skip_command(normalized_command):
        return 0

    privacy_filter = get_privacy_filter()
    safe_command = privacy_filter.mask(truncate_text(normalized_command, MAX_COMMAND_CHARS))
    resolved_cwd = resolve_cwd(cwd)
    repo_info = detect_git_context(resolved_cwd)
    resolved_repo_path = repo_path or repo_info.repo_path
    resolved_branch = branch or repo_info.branch
    resolved_status = status or status_from_exit_code(exit_code)
    resolved_duration_ms = duration_ms
    if resolved_duration_ms is None and duration_seconds is not None:
        resolved_duration_ms = int(duration_seconds * 1000)
    resolved_summary = summary or build_command_summary(
        safe_command,
        status=resolved_status,
        exit_code=exit_code,
    )

    details_json = {
        key: value
        for key, value in {
            "command": safe_command,
            "exit_code": exit_code,
            "duration_ms": resolved_duration_ms,
            "duration_seconds": duration_seconds,
            "cwd": compact_path(resolved_cwd) if resolved_cwd else None,
            "repo_path": resolved_repo_path,
            "branch": resolved_branch,
            "started_at": started_at,
            "ended_at": ended_at,
            "shell": shell,
            "tracking_mode": "command_hook" if source == "terminal" else None,
        }.items()
        if value is not None
    }
    occurred_at = parse_datetime(ended_at) or parse_datetime(started_at)

    request = build_dev_event_request(
        event_type=event_type,
        source=source,
        repo_path=resolved_repo_path,
        branch=resolved_branch,
        command=safe_command,
        status=resolved_status,
        summary=privacy_filter.mask(resolved_summary),
        details_json=details_json,
    )
    if occurred_at is not None:
        request = request.model_copy(update={"occurred_at": occurred_at})

    print_saved_event(save_dev_event(request, session_current=session_current))
    return 0


def normalize_command(command: str) -> str:
    return " ".join(command.split()).strip()


def should_skip_command(command: str) -> bool:
    if not command:
        return True
    first_word = command.split(maxsplit=1)[0]
    if first_word in IGNORED_COMMANDS:
        return True
    if any(marker in command for marker in HOOK_EXCLUDED_MARKERS):
        return True
    if _looks_like_env_file_read(command):
        return True
    return False


def _looks_like_env_file_read(command: str) -> bool:
    parts = command.split()
    if not parts or parts[0] not in ENV_READ_PREFIXES:
        return False
    return any(part == ".env" or part.startswith(".env.") or "/.env" in part for part in parts[1:])


def truncate_text(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 3].rstrip() + "..."


def status_from_exit_code(exit_code: int | None) -> str:
    if exit_code is None:
        return "unknown"
    return "success" if exit_code == 0 else "failed"


def build_command_summary(command: str, *, status: str, exit_code: int | None) -> str:
    if status == "success":
        return f"명령 성공: {command}"
    if exit_code is not None:
        return f"명령 실패: {command} exit_code={exit_code}"
    return f"명령 실패: {command}"


def resolve_cwd(cwd: str | None) -> Path | None:
    if not cwd:
        return None
    try:
        return Path(cwd).expanduser().resolve()
    except OSError:
        return Path(cwd).expanduser()


class GitContext:
    def __init__(self, *, repo_path: str | None = None, branch: str | None = None) -> None:
        self.repo_path = repo_path
        self.branch = branch


def detect_git_context(cwd: Path | None) -> GitContext:
    if cwd is None:
        return GitContext()
    repo_root = _git_stdout(cwd, "rev-parse", "--show-toplevel").strip()
    if not repo_root:
        return GitContext()
    branch = _git_stdout(cwd, "branch", "--show-current").strip()
    if not branch:
        branch = _git_stdout(cwd, "rev-parse", "--abbrev-ref", "HEAD").strip()
    return GitContext(
        repo_path=compact_path(Path(repo_root)),
        branch=branch or None,
    )


def _git_stdout(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return ""
    return result.stdout or ""


def parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def record_command_result_from_payload(payload: dict[str, Any]) -> int:
    return record_command_result(
        command=str(payload.get("command") or ""),
        status=payload.get("status"),
        summary=payload.get("summary"),
        event_type=str(payload.get("event_type") or "command_result"),
        exit_code=_optional_int(payload.get("exit_code")),
        duration_seconds=_optional_float(payload.get("duration_seconds")),
        duration_ms=_optional_int(payload.get("duration_ms")),
        cwd=payload.get("cwd"),
        repo_path=payload.get("repo_path"),
        branch=payload.get("branch"),
        started_at=payload.get("started_at"),
        ended_at=payload.get("ended_at"),
        shell=payload.get("shell"),
        source=str(payload.get("source") or "script"),
        session_current=bool(payload.get("session_current")),
    )


def _optional_int(value: Any) -> int | None:
    if value is None or value == "":
        return None
    return int(value)


def _optional_float(value: Any) -> float | None:
    if value is None or value == "":
        return None
    return float(value)


def main() -> int:
    parser = argparse.ArgumentParser(description="Record a command result as DevEvent.")
    parser.add_argument("--stdin-json", action="store_true")
    parser.add_argument("--command")
    parser.add_argument("--status", choices=["success", "failed", "unknown"])
    parser.add_argument("--summary")
    parser.add_argument(
        "--event-type",
        choices=["command_result", "test_result", "build_result", "note"],
        default="command_result",
    )
    parser.add_argument("--exit-code", type=int)
    parser.add_argument("--duration-seconds", type=float)
    parser.add_argument("--duration-ms", type=int)
    parser.add_argument("--cwd")
    parser.add_argument("--repo-path")
    parser.add_argument("--branch")
    parser.add_argument("--started-at")
    parser.add_argument("--ended-at")
    parser.add_argument("--shell")
    parser.add_argument(
        "--source",
        choices=["script", "api", "manual", "terminal"],
        default="script",
    )
    parser.add_argument("--session-current", action="store_true")
    args = parser.parse_args()

    if args.stdin_json:
        import sys

        payload = json.loads(sys.stdin.read() or "{}")
        return record_command_result_from_payload(payload)

    if not args.command:
        parser.error("--command is required unless --stdin-json is used")

    return record_command_result(
        command=args.command,
        status=args.status,
        summary=args.summary,
        event_type=args.event_type,
        exit_code=args.exit_code,
        duration_seconds=args.duration_seconds,
        duration_ms=args.duration_ms,
        cwd=args.cwd,
        repo_path=args.repo_path,
        branch=args.branch,
        started_at=args.started_at,
        ended_at=args.ended_at,
        shell=args.shell,
        source=args.source,
        session_current=args.session_current,
    )


if __name__ == "__main__":
    raise SystemExit(main())
