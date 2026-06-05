from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

from app.schemas.timeline import TimelineResponse
from app.services.privacy_filter import PrivacyFilter

try:
    from scripts.git_path_policies import TEMP_CACHE_IGNORE_PATTERNS
except ModuleNotFoundError:
    TEMP_CACHE_IGNORE_PATTERNS = (
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

EXCLUDED_PATH_PATTERNS = (
    ".env",
    ".env.*",
    "**/.env",
    "**/.env.*",
    "*.pem",
    "**/*.pem",
    "*.key",
    "**/*.key",
    "*.p12",
    "**/*.p12",
    "*.sqlite3",
    "**/*.sqlite3",
    "*.db",
    "**/*.db",
    "node_modules/**",
    ".venv/**",
    "venv/**",
    *TEMP_CACHE_IGNORE_PATTERNS,
    "**/__pycache__/**",
    ".pytest_cache/**",
    "DerivedData/**",
    "build/**",
    "dist/**",
    "htmlcov/**",
    "*.lock",
    "*.png",
    "*.jpg",
    "*.jpeg",
    "*.gif",
    "*.webp",
    "*.heic",
    "*.pdf",
    "*.mp3",
    "*.mp4",
    "*.mov",
    "*.wav",
    "*.m4a",
)
SAFE_UNTRACKED_SUFFIXES = (
    ".py",
    ".swift",
    ".js",
    ".ts",
    ".tsx",
    ".jsx",
    ".html",
    ".css",
    ".md",
    ".txt",
    ".toml",
    ".yaml",
    ".yml",
    ".json",
    ".sh",
)


@dataclass(frozen=True)
class GitDiffContext:
    repo_path: str
    branch: str
    content: str
    change_hints: list[str]
    truncated: bool = False


class GitDiffContextBuilder:
    def __init__(
        self,
        *,
        privacy_filter: PrivacyFilter,
        max_total_chars: int = 12000,
        max_file_chars: int = 3000,
        max_untracked_files: int = 5,
        max_hints: int = 8,
        max_hint_chars: int = 220,
        command_runner=None,
    ) -> None:
        self.privacy_filter = privacy_filter
        self.max_total_chars = max_total_chars
        self.max_file_chars = max_file_chars
        self.max_untracked_files = max_untracked_files
        self.max_hints = max_hints
        self.max_hint_chars = max_hint_chars
        self.command_runner = command_runner or subprocess.run

    def build_for_timeline(self, timeline: TimelineResponse) -> GitDiffContext | None:
        repo = self._select_repo_path(timeline)
        if repo is None:
            return None

        repo_root = self._git_stdout(repo, "rev-parse", "--show-toplevel").strip()
        if not repo_root:
            return None
        repo = Path(repo_root)
        branch = self._git_stdout(repo, "branch", "--show-current").strip() or "detached"

        diff_parts: list[str] = []
        tracked_diff = self._collect_tracked_diff(repo)
        if tracked_diff:
            diff_parts.append(tracked_diff)

        untracked_diff = self._collect_untracked_diff(repo)
        if untracked_diff:
            diff_parts.append(untracked_diff)

        content = "\n".join(part for part in diff_parts if part).strip()
        if not content:
            return None

        masked = self.privacy_filter.mask(content)
        change_hints = self._build_change_hints(masked)
        truncated_content, truncated = self._truncate_total(masked)
        return GitDiffContext(
            repo_path=str(repo),
            branch=branch,
            content=truncated_content,
            change_hints=change_hints,
            truncated=truncated,
        )

    def _select_repo_path(self, timeline: TimelineResponse) -> Path | None:
        for item in timeline.items:
            if item.type != "dev_event" or not item.repo_path:
                continue
            repo_path = Path(item.repo_path).expanduser()
            if not repo_path.is_absolute():
                repo_path = repo_path.resolve()
            return repo_path
        return None

    def _collect_tracked_diff(self, repo: Path) -> str:
        args = ["diff", "--patch", "HEAD", "--", "."]
        args.extend(f":(exclude){pattern}" for pattern in EXCLUDED_PATH_PATTERNS)
        diff = self._git_stdout(repo, *args)
        return self._truncate_file_sections(diff)

    def _collect_untracked_diff(self, repo: Path) -> str:
        files = self._git_stdout(
            repo,
            "ls-files",
            "--others",
            "--exclude-standard",
        ).splitlines()
        safe_files = [
            file_path
            for file_path in files
            if self._is_safe_untracked_file(repo / file_path)
        ][: self.max_untracked_files]
        if not safe_files:
            return ""

        sections: list[str] = []
        for file_path in safe_files:
            diff = self._run_no_index_diff(repo, file_path)
            if diff:
                sections.append(self._truncate_file_sections(diff))
        return "\n".join(sections)

    def _run_no_index_diff(self, repo: Path, file_path: str) -> str:
        result = self.command_runner(
            ["git", "-C", str(repo), "diff", "--no-index", "--", "/dev/null", file_path],
            check=False,
            capture_output=True,
            text=True,
        )
        stdout = getattr(result, "stdout", "") or ""
        stderr = getattr(result, "stderr", "") or ""
        output = stdout or stderr
        if "Binary files" in output:
            return f"diff --git a/{file_path} b/{file_path}\nBinary file excluded\n"
        return output

    def _is_safe_untracked_file(self, path: Path) -> bool:
        if not path.is_file():
            return False
        if path.suffix.lower() not in SAFE_UNTRACKED_SUFFIXES:
            return False
        try:
            if path.stat().st_size > self.max_file_chars * 2:
                return False
        except OSError:
            return False
        lowered = path.name.lower()
        return not (
            lowered.startswith(".env")
            or lowered.endswith((".pem", ".key", ".p12", ".sqlite3", ".db"))
        )

    def _truncate_file_sections(self, diff: str) -> str:
        if not diff:
            return ""
        sections = diff.split("\ndiff --git ")
        normalized_sections: list[str] = []
        for index, section in enumerate(sections):
            if not section:
                continue
            text = section if index == 0 else "diff --git " + section
            if len(text) > self.max_file_chars:
                text = text[: self.max_file_chars].rstrip() + "\n... diff 일부 생략 ..."
            normalized_sections.append(text)
        return "\n".join(normalized_sections)

    def _truncate_total(self, text: str) -> tuple[str, bool]:
        if len(text) <= self.max_total_chars:
            return text, False
        return text[: self.max_total_chars].rstrip() + "\n... diff 일부 생략 ...", True

    def _build_change_hints(self, diff: str) -> list[str]:
        hints: list[str] = []
        for file_path, section in self._iter_diff_sections(diff):
            labels = self._infer_change_labels(file_path, section)
            if not labels:
                continue
            hint = f"{file_path}: {', '.join(labels[:4])} 관련 변경"
            hints.append(self._truncate_hint(self.privacy_filter.mask(hint)))
            if len(hints) >= self.max_hints:
                break
        return hints

    def _iter_diff_sections(self, diff: str):
        for raw_section in diff.split("\ndiff --git "):
            section = raw_section.strip()
            if not section:
                continue
            if not section.startswith("diff --git "):
                section = "diff --git " + section
            file_path = self._extract_diff_file_path(section)
            if file_path:
                yield file_path, section

    def _extract_diff_file_path(self, section: str) -> str:
        first_line = section.splitlines()[0] if section.splitlines() else ""
        parts = first_line.split()
        if len(parts) >= 4 and parts[0] == "diff" and parts[1] == "--git":
            return parts[3].removeprefix("b/")
        return ""

    def _infer_change_labels(self, file_path: str, section: str) -> list[str]:
        searchable = f"{file_path}\n{section}".lower()
        labels: list[str] = []
        rules = (
            (
                "Dev Tracking persistent state",
                ("devtrackingstatestore", "state_path", "tracking_signature", "persistent"),
            ),
            (
                "TTL dedupe",
                ("dedupe_ttl_seconds", "ttl", "expires_at", "updated_at"),
            ),
            (
                "debounce 안정화",
                ("debounce_seconds", "pendingsignature", "pending_signatures", "stable_since"),
            ),
            (
                "temp/cache ignore 정책",
                (".swp", ".swo", "__pycache__", ".pytest_cache", "tracking ignore"),
            ),
            (
                "watcher CLI 옵션",
                ("--state-path", "--debounce-seconds", "--dedupe-ttl-seconds", "--once"),
            ),
            (
                "watcher stdout/stderr 상태 표시",
                ("standardoutput", "standarderror", "pipe", "pythonunbuffered", "stdout", "stderr"),
            ),
            (
                "repo path 설정/검증",
                ("devtrackingrepopath", "userdefaults", "rev-parse", "show-toplevel"),
            ),
            (
                "report input 20분 압축",
                ("dev_event_group", "20", "twenty", "bucket", "time_range"),
            ),
            (
                "CURRENT_GIT_DIFF_CONTEXT 우선순위",
                ("current_git_diff_context", "priority_current_git_diff_context"),
            ),
            (
                "구체 변경 의도 힌트",
                ("current_git_change_hints", "priority_current_git_change_hints", "change_hints"),
            ),
        )
        for label, keywords in rules:
            if any(keyword in searchable for keyword in keywords):
                labels.append(label)
        return labels

    def _truncate_hint(self, text: str) -> str:
        if len(text) <= self.max_hint_chars:
            return text
        return text[: self.max_hint_chars].rstrip() + "..."

    def _git_stdout(self, repo: Path, *args: str) -> str:
        result = self.command_runner(
            ["git", "-C", str(repo), *args],
            check=False,
            capture_output=True,
            text=True,
        )
        if getattr(result, "returncode", 1) != 0:
            return ""
        return getattr(result, "stdout", "") or ""
