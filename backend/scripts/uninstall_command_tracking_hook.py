from __future__ import annotations

import argparse
from pathlib import Path

try:
    from scripts._bootstrap import add_backend_root_to_path
except ModuleNotFoundError:
    from _bootstrap import add_backend_root_to_path

add_backend_root_to_path()

try:
    from scripts.install_command_tracking_hook import HOOK_MARKER, default_hook_path, source_line
except ModuleNotFoundError:
    from install_command_tracking_hook import HOOK_MARKER, default_hook_path, source_line


def uninstall_hook(
    *,
    zshrc_path: Path | None = None,
    hook_path: Path | None = None,
) -> bool:
    zshrc_path = zshrc_path or Path.home() / ".zshrc"
    hook_path = hook_path or default_hook_path()
    if not zshrc_path.exists():
        return False

    target_line = source_line(hook_path)
    lines = zshrc_path.read_text(encoding="utf-8").splitlines()
    filtered: list[str] = []
    removed = False
    index = 0
    while index < len(lines):
        line = lines[index]
        if line == HOOK_MARKER and index + 1 < len(lines) and lines[index + 1] == target_line:
            removed = True
            index += 2
            continue
        if line == target_line:
            removed = True
            index += 1
            continue
        filtered.append(line)
        index += 1

    if removed:
        zshrc_path.write_text("\n".join(filtered).rstrip() + "\n", encoding="utf-8")
    return removed


def main() -> int:
    parser = argparse.ArgumentParser(description="Uninstall Mwoham zsh command tracking hook.")
    parser.add_argument("--zshrc", type=Path)
    parser.add_argument("--hook-path", type=Path)
    args = parser.parse_args()

    removed = uninstall_hook(zshrc_path=args.zshrc, hook_path=args.hook_path)
    zshrc_path = args.zshrc or Path.home() / ".zshrc"
    if removed:
        print(f"Mwoham command tracking hook removed: {zshrc_path}")
    else:
        print(f"Mwoham command tracking hook was not installed: {zshrc_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
