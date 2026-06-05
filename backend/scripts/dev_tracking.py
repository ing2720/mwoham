from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from fnmatch import fnmatch

try:
    from scripts.collect_git_snapshot import GitStatusSnapshot, collect_git_status_snapshot
    from scripts.dev_event_helpers import (
        build_dev_event_request,
        compact_path,
        print_saved_event,
        save_dev_event,
    )
except ModuleNotFoundError:
    from collect_git_snapshot import GitStatusSnapshot, collect_git_status_snapshot
    from dev_event_helpers import (
        build_dev_event_request,
        compact_path,
        print_saved_event,
        save_dev_event,
    )


@dataclass(frozen=True)
class DevTrackingResult:
    status: str
    signature: str | None = None
    summary: str | None = None


class DevContextTracker:
    def __init__(self) -> None:
        self.last_signature: str | None = None

    def check_once(self, repo_path: str, *, session_current: bool = False) -> DevTrackingResult:
        snapshot = collect_git_status_snapshot(repo_path)
        if snapshot is None:
            return DevTrackingResult(status="not_git_repo")

        tracked_snapshot = filter_ignored_tracking_files(snapshot)
        signature = build_git_tracking_signature(tracked_snapshot)
        if signature == self.last_signature:
            return DevTrackingResult(status="unchanged", signature=signature)

        self.last_signature = signature
        if not tracked_snapshot.dirty:
            return DevTrackingResult(status="clean", signature=signature)

        summary = build_git_tracking_summary(tracked_snapshot)
        request = build_dev_event_request(
            event_type="git_snapshot",
            source="script",
            repo_path=compact_path(tracked_snapshot.repo),
            branch=tracked_snapshot.branch,
            status="unknown",
            summary=summary,
            details_json={
                "tracking_mode": "watch",
                "tracking_signature": signature,
                "head_commit": tracked_snapshot.head_commit,
                "dirty": tracked_snapshot.dirty,
                "changed_files": tracked_snapshot.changed_files[:80],
                "git_status_summary": summarize_git_status(tracked_snapshot.status_short),
                "git_status_short": tracked_snapshot.status_short[:80],
            },
        )
        print_saved_event(save_dev_event(request, session_current=session_current))
        return DevTrackingResult(status="saved", signature=signature, summary=summary)


TRACKING_IGNORE_PATTERNS = (
    "*.swp",
    "*.swo",
    ".*.swp",
    ".*.swo",
    "*~",
    ".DS_Store",
    "__pycache__/",
    ".pytest_cache/",
    ".coverage",
    "coverage.xml",
    "htmlcov/",
)


def filter_ignored_tracking_files(snapshot: GitStatusSnapshot) -> GitStatusSnapshot:
    status_short = [
        line for line in snapshot.status_short if not is_ignored_tracking_status(line)
    ]
    changed_files = [
        file_path for file_path in snapshot.changed_files if not is_ignored_tracking_path(file_path)
    ]
    return GitStatusSnapshot(
        repo=snapshot.repo,
        branch=snapshot.branch,
        head_commit=snapshot.head_commit,
        status_short=status_short,
        changed_files=changed_files,
        dirty=bool(status_short),
    )


def is_ignored_tracking_status(status_line: str) -> bool:
    return is_ignored_tracking_path(_path_from_status_line(status_line))


def is_ignored_tracking_path(file_path: str) -> bool:
    normalized = file_path.strip().replace("\\", "/")
    if not normalized:
        return False
    for pattern in TRACKING_IGNORE_PATTERNS:
        if _matches_ignore_pattern(normalized, pattern):
            return True
    return False


def _matches_ignore_pattern(file_path: str, pattern: str) -> bool:
    if pattern.endswith("/"):
        prefix = pattern.rstrip("/")
        return (
            file_path == prefix
            or file_path.startswith(f"{prefix}/")
            or f"/{prefix}/" in file_path
        )
    return fnmatch(file_path, pattern) or fnmatch(file_path.rsplit("/", 1)[-1], pattern)


def _path_from_status_line(status_line: str) -> str:
    if not status_line.strip():
        return ""
    file_path = status_line[3:].strip()
    if " -> " in file_path:
        file_path = file_path.split(" -> ", 1)[1].strip()
    return file_path


def build_git_tracking_signature(snapshot: GitStatusSnapshot) -> str:
    payload = {
        "branch": snapshot.branch,
        "head_commit": snapshot.head_commit,
        "status_short": sorted(snapshot.status_short),
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def build_git_tracking_summary(snapshot: GitStatusSnapshot) -> str:
    count = len(snapshot.changed_files)
    file_label = "file" if count == 1 else "files"
    return f"Git 변경 감지: {count} {file_label} changed on {snapshot.branch}"


def summarize_git_status(status_short: list[str]) -> dict[str, int]:
    summary = {
        "staged": 0,
        "unstaged": 0,
        "untracked": 0,
    }
    for line in status_short:
        if line.startswith("??"):
            summary["untracked"] += 1
            continue
        staged_status = line[:1]
        unstaged_status = line[1:2]
        if staged_status.strip():
            summary["staged"] += 1
        if unstaged_status.strip():
            summary["unstaged"] += 1
    return summary
