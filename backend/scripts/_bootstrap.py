import sys
from pathlib import Path


def add_backend_root_to_path() -> None:
    backend_root = Path(__file__).resolve().parents[1]
    backend_root_text = str(backend_root)
    if backend_root_text not in sys.path:
        sys.path.insert(0, backend_root_text)
