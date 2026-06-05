from __future__ import annotations

import hashlib
import json
import os
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

try:
    from scripts.collect_git_snapshot import GitStatusSnapshot, collect_git_status_snapshot
    from scripts.dev_event_helpers import (
        build_dev_event_request,
        compact_path,
        print_saved_event,
        save_dev_event,
    )
    from scripts.git_path_policies import TEMP_CACHE_IGNORE_PATTERNS, is_ignored_temp_cache_path
except ModuleNotFoundError:
    from collect_git_snapshot import GitStatusSnapshot, collect_git_status_snapshot
    from dev_event_helpers import (
        build_dev_event_request,
        compact_path,
        print_saved_event,
        save_dev_event,
    )
    from git_path_policies import TEMP_CACHE_IGNORE_PATTERNS, is_ignored_temp_cache_path


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
                "diff_summary": collect_git_diff_summary(tracked_snapshot)[:80],
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


TRACKING_IGNORE_PATTERNS = TEMP_CACHE_IGNORE_PATTERNS


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
    return is_ignored_temp_cache_path(file_path)


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


def collect_git_diff_summary(snapshot: GitStatusSnapshot) -> list[dict[str, object]]:
    status_by_path = {
        _path_from_status_line(line): _status_type(line)
        for line in snapshot.status_short
        if _path_from_status_line(line)
    }
    summary_by_file: dict[str, dict[str, object]] = {}
    for line in _run_git_numstat(snapshot.repo):
        item = _parse_numstat_line(line)
        if item is None:
            continue
        file_path = str(item["file"])
        if is_ignored_tracking_path(file_path):
            continue
        item["status"] = status_by_path.get(file_path, "modified")
        summary_by_file[file_path] = item

    for file_path in snapshot.changed_files:
        if file_path in summary_by_file:
            continue
        status = status_by_path.get(file_path, "modified")
        if status == "untracked":
            summary_by_file[file_path] = {
                "file": file_path,
                "status": "untracked",
                "untracked": True,
            }

    return [
        summary_by_file[file_path]
        for file_path in snapshot.changed_files
        if file_path in summary_by_file
    ]


def _run_git_numstat(repo: Path) -> list[str]:
    import subprocess

    result = subprocess.run(
        ["git", "-C", str(repo), "diff", "--numstat", "HEAD", "--"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []
    return result.stdout.splitlines()


def _parse_numstat_line(line: str) -> dict[str, object] | None:
    parts = line.split("\t")
    if len(parts) < 3:
        return None
    insertions, deletions, file_path = parts[0], parts[1], parts[2]
    if " => " in file_path:
        file_path = _normalize_numstat_rename_path(file_path)
    if insertions == "-" or deletions == "-":
        return {
            "file": file_path,
            "binary": True,
        }
    return {
        "file": file_path,
        "insertions": int(insertions),
        "deletions": int(deletions),
    }


def _normalize_numstat_rename_path(file_path: str) -> str:
    if " => " not in file_path:
        return file_path
    suffix = file_path.split(" => ", 1)[1]
    if "}" in suffix:
        suffix = suffix.split("}", 1)[1]
    return suffix.strip()


def _status_type(status_line: str) -> str:
    if status_line.startswith("??"):
        return "untracked"
    staged_status = status_line[:1]
    unstaged_status = status_line[1:2]
    if staged_status.strip() and unstaged_status.strip():
        return "staged_unstaged"
    if staged_status.strip():
        return "staged"
    if unstaged_status.strip():
        return "unstaged"
    return "modified"
