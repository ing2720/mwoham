#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
BASE_URL="${MWOHAM_BACKEND_URL:-http://127.0.0.1:8765}"
CREATE_REPORT=0

if [[ "${1:-}" == "--create-report" ]]; then
    CREATE_REPORT=1
fi

cd "$BACKEND_DIR"

uv run python - "$BASE_URL" "$CREATE_REPORT" <<'PY'
import collections
import json
import sys
import urllib.error
import urllib.request

base_url = sys.argv[1].rstrip("/")
create_report = sys.argv[2] == "1"


def request_json(path: str, *, method: str = "GET") -> object:
    request = urllib.request.Request(
        f"{base_url}{path}",
        method=method,
        headers={"Accept": "application/json"},
    )
    if method == "POST":
        request.add_header("Content-Type", "application/json")
        request.data = b"{}"
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.load(response)


def items_from(payload: object) -> list[dict]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if not isinstance(payload, dict):
        return []
    for key in ("items", "events", "memos", "reports"):
        value = payload.get(key)
        if isinstance(value, list):
            return [item for item in value if isinstance(item, dict)]
    return []


def summarize(path: str) -> None:
    try:
        payload = request_json(path)
    except urllib.error.URLError as exc:
        print(f"{path}: error={exc}")
        return
    items = items_from(payload)
    total = payload.get("total") if isinstance(payload, dict) else len(items)
    types = collections.Counter(
        item.get("type") or item.get("event_type") or item.get("source") or "-"
        for item in items
    )
    hidden = sum(1 for item in items if item.get("hidden_by_default"))
    low = sum(1 for item in items if item.get("signal_level") == "low_signal")
    timestamps = [item.get("timestamp") for item in items if item.get("timestamp")]
    print(
        f"{path}: total={total} items={len(items)} "
        f"types={dict(types.most_common(8))} hidden={hidden} low={low}"
    )
    if timestamps:
        print(f"{path}: first={timestamps[0]} last={timestamps[-1]}")


print(f"backend={base_url}")
print(f"/health: {request_json('/health')}")
for path in (
    "/timeline/today",
    "/timeline/today/detail",
    "/events",
    "/memos",
    "/reports/today",
):
    summarize(path)

if create_report:
    report = request_json("/reports/daily", method="POST")
    if isinstance(report, dict):
        print(
            "/reports/daily: "
            f"id={report.get('id')} mode={report.get('mode')} "
            f"created_by={report.get('created_by')}"
        )
PY
