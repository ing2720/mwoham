from __future__ import annotations

import argparse
from pathlib import Path

try:
    from scripts._bootstrap import add_backend_root_to_path
except ModuleNotFoundError:
    from _bootstrap import add_backend_root_to_path

add_backend_root_to_path()

try:
    from scripts.dev_event_helpers import resolve_backend_root
except ModuleNotFoundError:
    from dev_event_helpers import resolve_backend_root


HOOK_MARKER = "# Mwoham command tracking"


def default_hook_path() -> Path:
    return resolve_backend_root() / "scripts" / "mwoham_zsh_tracking.zsh"


def source_line(hook_path: Path) -> str:
    return f'source "{hook_path.expanduser().resolve()}"'


def activation_instructions() -> list[str]:
    return [
        "설치 스크립트는 ~/.zshrc에 source line만 추가합니다.",
        "현재 shell에서는 source ~/.zshrc를 실행하거나 새 터미널을 열어야 활성화됩니다.",
        "활성 상태 확인: mwoham_command_tracking_status",
    ]


def install_hook(
    *,
    zshrc_path: Path | None = None,
    hook_path: Path | None = None,
) -> bool:
    zshrc_path = zshrc_path or Path.home() / ".zshrc"
    hook_path = hook_path or default_hook_path()
    line = source_line(hook_path)
    block = f"\n{HOOK_MARKER}\n{line}\n"

    existing = zshrc_path.read_text(encoding="utf-8") if zshrc_path.exists() else ""
    if line in existing:
        return False

    lines = existing.splitlines(keepends=True)
    updated_lines: list[str] = []
    changed = False
    index = 0
    while index < len(lines):
        if lines[index].strip() == HOOK_MARKER:
            updated_lines.append(f"{HOOK_MARKER}\n")
            updated_lines.append(f"{line}\n")
            index += 1
            while index < len(lines) and lines[index].lstrip().startswith("source "):
                index += 1
            changed = True
            continue
        updated_lines.append(lines[index])
        index += 1

    if changed:
        zshrc_path.write_text("".join(updated_lines), encoding="utf-8")
        return True

    zshrc_path.parent.mkdir(parents=True, exist_ok=True)
    with zshrc_path.open("a", encoding="utf-8") as file:
        file.write(block)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Install Mwoham zsh command tracking hook.")
    parser.add_argument("--zshrc", type=Path)
    parser.add_argument("--hook-path", type=Path)
    args = parser.parse_args()

    added = install_hook(zshrc_path=args.zshrc, hook_path=args.hook_path)
    hook_path = args.hook_path or default_hook_path()
    zshrc_path = args.zshrc or Path.home() / ".zshrc"
    if added:
        print(f"Mwoham command tracking hook installed: {zshrc_path}")
    else:
        print(f"Mwoham command tracking hook already installed: {zshrc_path}")
    print(f"source line: {source_line(hook_path)}")
    for line in activation_instructions():
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
