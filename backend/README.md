# Mwoham Backend

Local FastAPI backend for the macOS AI worklog agent.

## Setup

```bash
cd backend
uv sync
```

## Run

```bash
uv run uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload
```

Health check:

```bash
curl http://127.0.0.1:8765/health
```

## Alembic

```bash
uv run alembic revision --autogenerate -m "message"
uv run alembic upgrade head
```
