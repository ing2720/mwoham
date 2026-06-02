from __future__ import annotations

import argparse
import re
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

try:
    from scripts._bootstrap import add_backend_root_to_path
except ModuleNotFoundError:
    from _bootstrap import add_backend_root_to_path

add_backend_root_to_path()

from app.core.timezone import now_utc  # noqa: E402
from app.db.session import SessionLocal  # noqa: E402
from app.schemas.dev_event import DevEventCreate  # noqa: E402
from app.services.dev_event_service import get_dev_event_service  # noqa: E402

OUTPUT_EXCERPT_LIMIT = 1000


@dataclass(frozen=True)
class DevCheck:
    command: list[str]
    event_type: str
    cwd: Path

    @property
    def command_text(self) -> str:
        return " ".join(self.command)


@dataclass(frozen=True)
class DevCheckResult:
    check: DevCheck
    exit_code: int
    duration_seconds: float
    output_excerpt: str

    @property
    def status(self) -> str:
        return "success" if self.exit_code == 0 else "failed"


def run_dev_checks(
    *,
    repo_path: str | None = None,
    session_current: bool = False,
    no_record: bool = False,
) -> int:
    backend_root = Path(__file__).resolve().parents[1]
    project_root = Path(repo_path).expanduser().resolve() if repo_path else backend_root.parent
    checks = [
        DevCheck(["uv", "run", "ruff", "check", "."], "test_result", backend_root),
        DevCheck(["uv", "run", "pytest"], "test_result", backend_root),
        DevCheck(["uv", "run", "alembic", "check"], "command_result", backend_root),
        DevCheck(["git", "diff", "--check"], "command_result", project_root),
    ]

    results: list[DevCheckResult] = []
    for check in checks:
        result = _run_check(check)
        if not no_record:
            _save_result(result, repo_path=str(project_root), session_current=session_current)
        results.append(result)
        print(_format_result_line(result))

    success_count = sum(result.status == "success" for result in results)
    failed_results = [result for result in results if result.status == "failed"]
    print(f"전체 요약: 통과 {success_count}개, 실패 {len(failed_results)}개")
    if failed_results:
        failed_commands = ", ".join(result.check.command_text for result in failed_results)
        print(f"실패 명령: {failed_commands}")
        return 1
    return 0


def _run_check(check: DevCheck) -> DevCheckResult:
    started_at = time.monotonic()
    completed = _run_command(check.command, cwd=check.cwd)
    duration_seconds = time.monotonic() - started_at
    output = "\n".join(value for value in [completed.stdout, completed.stderr] if value)
    return DevCheckResult(
        check=check,
        exit_code=completed.returncode,
        duration_seconds=round(duration_seconds, 3),
        output_excerpt=_excerpt_for_command(check.command_text, output),
    )


def _run_command(command: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
    )


def _save_result(
    result: DevCheckResult,
    *,
    repo_path: str,
    session_current: bool,
) -> None:
    request = DevEventCreate(
        event_type=result.check.event_type,
        source="script",
        repo_path=repo_path,
        command=result.check.command_text,
        status=result.status,
        summary=_summary(result),
        details_json={
            "exit_code": result.exit_code,
            "duration_seconds": result.duration_seconds,
            "output_excerpt": result.output_excerpt,
        },
        occurred_at=now_utc(),
    )

    with SessionLocal() as db:
        service = get_dev_event_service()
        if session_current:
            service.create_for_current_session(db, request)
        else:
            service.create(db, request)


def _summary(result: DevCheckResult) -> str:
    label = "통과" if result.status == "success" else "실패"
    return f"{result.check.command_text}: {label}"


def _format_result_line(result: DevCheckResult) -> str:
    return (
        f"{result.check.command_text}: {result.status} "
        f"(exit_code={result.exit_code}, {result.duration_seconds:.3f}s)"
    )


def _excerpt_for_command(command_text: str, output: str) -> str:
    lines = _meaningful_lines(output)
    if command_text == "uv run pytest":
        return _limit_text(_pytest_excerpt(lines))
    if command_text == "uv run ruff check .":
        return _limit_text(_ruff_excerpt(lines))
    if command_text == "uv run alembic check":
        return _limit_text(_alembic_excerpt(lines))
    if command_text == "git diff --check":
        return _limit_text(_git_diff_check_excerpt(lines))
    return _limit_text(_generic_excerpt(lines))


def _meaningful_lines(output: str) -> list[str]:
    return [line.strip() for line in output.splitlines() if line.strip()]


def _pytest_excerpt(lines: list[str]) -> str:
    result_pattern = re.compile(
        r"=+\s*(?P<summary>.+?(?:passed|failed|errors?|skipped|xfailed|xpassed).+?)\s*=+$",
        re.IGNORECASE,
    )
    for line in reversed(lines):
        match = result_pattern.match(line)
        if match:
            return match.group("summary")

    failure_lines = [
        line
        for line in lines
        if "failed" in line.lower() or "error" in line.lower() or line.startswith("FAILED ")
    ]
    if failure_lines:
        return " / ".join(failure_lines[-6:])
    return _generic_excerpt(lines)


def _ruff_excerpt(lines: list[str]) -> str:
    for line in lines:
        if line == "All checks passed!":
            return line
    issue_lines = [
        line
        for line in lines
        if re.match(r"^[A-Z]\d{3}\b", line) or line.startswith("Found ")
    ]
    return " / ".join(issue_lines[:8]) if issue_lines else _generic_excerpt(lines)


def _alembic_excerpt(lines: list[str]) -> str:
    preferred = [
        line
        for line in lines
        if "No new upgrade operations detected." in line
        or "FAILED:" in line
        or "Target database is not up to date" in line
    ]
    if preferred:
        return " / ".join(preferred)
    filtered = [line for line in lines if "setting up autogenerate plugin" not in line]
    return _generic_excerpt(filtered)


def _git_diff_check_excerpt(lines: list[str]) -> str:
    if not lines:
        return "No whitespace errors"
    return " / ".join(lines[:10])


def _generic_excerpt(lines: list[str]) -> str:
    if not lines:
        return ""
    return " / ".join(lines[-8:])


def _limit_text(text: str) -> str:
    normalized = " ".join(text.split())
    if len(normalized) <= OUTPUT_EXCERPT_LIMIT:
        return normalized
    truncated_lines: list[str] = []
    current_length = 0
    for line in normalized.split(" / "):
        next_length = current_length + len(line) + (3 if truncated_lines else 0)
        if next_length > OUTPUT_EXCERPT_LIMIT - 3:
            break
        truncated_lines.append(line)
        current_length = next_length
    if truncated_lines:
        return " / ".join(truncated_lines) + "..."
    return normalized[: OUTPUT_EXCERPT_LIMIT - 3].rstrip() + "..."


def main() -> int:
    parser = argparse.ArgumentParser(description="Run development checks and record DevEvents.")
    parser.add_argument("--repo-path")
    parser.add_argument("--session-current", action="store_true")
    parser.add_argument("--no-record", action="store_true")
    args = parser.parse_args()
    return run_dev_checks(
        repo_path=args.repo_path,
        session_current=args.session_current,
        no_record=args.no_record,
    )


if __name__ == "__main__":
    raise SystemExit(main())
