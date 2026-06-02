from __future__ import annotations

import argparse
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

OUTPUT_EXCERPT_LIMIT = 1200


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


def run_dev_checks(*, repo_path: str | None = None, session_current: bool = False) -> int:
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
        output_excerpt=_excerpt(output),
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


def _excerpt(output: str) -> str:
    normalized = " ".join(output.split())
    if len(normalized) <= OUTPUT_EXCERPT_LIMIT:
        return normalized
    return normalized[:OUTPUT_EXCERPT_LIMIT].rstrip() + "..."


def main() -> int:
    parser = argparse.ArgumentParser(description="Run development checks and record DevEvents.")
    parser.add_argument("--repo-path")
    parser.add_argument("--session-current", action="store_true")
    args = parser.parse_args()
    return run_dev_checks(repo_path=args.repo_path, session_current=args.session_current)


if __name__ == "__main__":
    raise SystemExit(main())
