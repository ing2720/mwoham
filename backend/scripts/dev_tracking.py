from __future__ import annotations

import hashlib
import json
import os
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from fnmatch import fnmatch
from pathlib import Path

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


@dataclass(frozen=True)
class DevTrackingStateEntry:
    signature: str
    updated_at: datetime


@dataclass(frozen=True)
class PendingTrackingSignature:
    signature: str
    first_seen_at: datetime


class DevContextTracker:
    def __init__(
        self,
        *,
        state_store: DevTrackingStateStore | None = None,
        state_path: Path | None = None,
        dedupe_ttl_seconds: int = 21600,
        debounce_seconds: int = 0,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.state_store = state_store or DevTrackingStateStore(state_path)
        self.dedupe_ttl_seconds = dedupe_ttl_seconds
        self.debounce_seconds = debounce_seconds
        self.now = now or _now_utc
        self.pending_signatures: dict[str, PendingTrackingSignature] = {}

    def check_once(self, repo_path: str, *, session_current: bool = False) -> DevTrackingResult:
        snapshot = collect_git_status_snapshot(repo_path)
        if snapshot is None:
            return DevTrackingResult(status="not_git_repo")

        tracked_snapshot = filter_ignored_tracking_files(snapshot)
        signature = build_git_tracking_signature(tracked_snapshot)
        repo_key = build_repo_state_key(tracked_snapshot.repo)
        current_time = self.now()
        state_entry = self.state_store.get_entry(repo_key)
        if self._is_deduped(signature, state_entry, current_time):
            return DevTrackingResult(status="unchanged", signature=signature)

        if not tracked_snapshot.dirty:
            self.pending_signatures.pop(repo_key, None)
            self.state_store.set_signature(repo_key, signature, updated_at=current_time)
            return DevTrackingResult(status="clean", signature=signature)

        pending_result = self._wait_for_debounce(repo_key, signature, current_time)
        if pending_result is not None:
            return pending_result

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
        self.pending_signatures.pop(repo_key, None)
        self.state_store.set_signature(repo_key, signature, updated_at=current_time)
        return DevTrackingResult(status="saved", signature=signature, summary=summary)

    def _is_deduped(
        self,
        signature: str,
        state_entry: DevTrackingStateEntry | None,
        current_time: datetime,
    ) -> bool:
        if state_entry is None or state_entry.signature != signature:
            return False
        if self.dedupe_ttl_seconds <= 0:
            return False
        expires_at = state_entry.updated_at + timedelta(seconds=self.dedupe_ttl_seconds)
        return current_time < expires_at

    def _wait_for_debounce(
        self,
        repo_key: str,
        signature: str,
        current_time: datetime,
    ) -> DevTrackingResult | None:
        if self.debounce_seconds <= 0:
            return None

        pending = self.pending_signatures.get(repo_key)
        if pending is None or pending.signature != signature:
            self.pending_signatures[repo_key] = PendingTrackingSignature(
                signature=signature,
                first_seen_at=current_time,
            )
            return DevTrackingResult(status="pending", signature=signature)

        stable_since = current_time - pending.first_seen_at
        if stable_since < timedelta(seconds=self.debounce_seconds):
            return DevTrackingResult(status="pending", signature=signature)
        return None


class DevTrackingStateStore:
    def __init__(self, state_path: Path | None = None) -> None:
        self.state_path = state_path or get_default_state_path()

    def get_signature(self, repo_key: str) -> str | None:
        entry = self.get_entry(repo_key)
        return entry.signature if entry is not None else None

    def get_entry(self, repo_key: str) -> DevTrackingStateEntry | None:
        data = self._read()
        repo_state = data.get("repos", {}).get(repo_key, {})
        signature = repo_state.get("signature")
        updated_at = _parse_state_datetime(repo_state.get("updated_at"))
        if not isinstance(signature, str) or updated_at is None:
            return None
        return DevTrackingStateEntry(signature=signature, updated_at=updated_at)

    def set_signature(
        self,
        repo_key: str,
        signature: str,
        *,
        updated_at: datetime | None = None,
    ) -> None:
        data = self._read()
        repos = data.setdefault("repos", {})
        repos[repo_key] = {
            "signature": signature,
            "updated_at": (updated_at or _now_utc()).isoformat(),
        }
        data["version"] = 1
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text(
            json.dumps(data, ensure_ascii=False, sort_keys=True),
            encoding="utf-8",
        )

    def _read(self) -> dict:
        if not self.state_path.exists():
            return {"version": 1, "repos": {}}
        try:
            data = json.loads(self.state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {"version": 1, "repos": {}}
        if not isinstance(data, dict):
            return {"version": 1, "repos": {}}
        if not isinstance(data.get("repos"), dict):
            data["repos"] = {}
        return data


def get_default_state_path() -> Path:
    configured_path = os.environ.get("MWOHAM_DEV_TRACKING_STATE_PATH")
    if configured_path:
        return Path(configured_path).expanduser()
    return Path(tempfile.gettempdir()) / "mwoham-dev-tracking-state.json"


def build_repo_state_key(repo_path: Path) -> str:
    try:
        return str(repo_path.resolve())
    except OSError:
        return str(repo_path)


def _now_utc() -> datetime:
    return datetime.now(UTC)


def _parse_state_datetime(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


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
