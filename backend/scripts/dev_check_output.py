from __future__ import annotations

import re

OUTPUT_EXCERPT_LIMIT = 1000


def excerpt_for_command(command_text: str, output: str) -> str:
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
