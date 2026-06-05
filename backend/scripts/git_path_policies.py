from __future__ import annotations

from fnmatch import fnmatch

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


def is_ignored_temp_cache_path(file_path: str) -> bool:
    normalized = file_path.strip().replace("\\", "/")
    if not normalized:
        return False
    for pattern in TEMP_CACHE_IGNORE_PATTERNS:
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
