# Mwoham Backend

Mwoham Backend는 macOS 앱과 연결되는 로컬 FastAPI 서버입니다. 작업 기록, 앱/창 구간, OCR 텍스트, 메모, 회의 전사, DevEvent를 SQLite에 저장하고 Timeline/Daily Report/Dashboard로 재구성합니다.

기본 주소는 `http://127.0.0.1:8765`이고 상태 확인 endpoint는 `GET /health`입니다.

## 기술 스택

- Python 3.12+
- FastAPI
- Uvicorn
- SQLAlchemy ORM
- Alembic
- SQLite
- Pydantic / pydantic-settings
- Jinja2
- Markdown
- WeasyPrint
- uv
- pytest / pytest-cov
- ruff

## 구조

```text
backend/
  app/
    ai/                 Gemini/OpenAI clients, prompt builder, report cleaner
    api/endpoints/      JSON API routers
    core/               config, security, exceptions, timezone
    db/                 SQLAlchemy session, DB init
    models/             SQLAlchemy models
    report/             Markdown/PDF export
    repositories/       DB access layer
    schemas/            Pydantic request/response schemas
    services/           business logic
    web/                Jinja2 routes/templates
  alembic/              migrations
  scripts/              dev tracking, checks, sample/reset utilities
  tests/                pytest suite
```

원칙:

- `router -> service -> repository` 흐름을 유지합니다.
- 라우터에 DB 쿼리를 직접 작성하지 않습니다.
- ORM model을 외부 API response로 직접 노출하지 않습니다.
- 모델 변경이 없는 작업에서는 migration을 만들지 않습니다.
- 실제 API Key, `.env`, DB, export, 모델/runtime 파일을 git에 포함하지 않습니다.

## 주요 기능

- health/status API
- recording session 제어
- work event 저장
- activity segment 저장
- screen observation 저장
- manual memo 저장
- meeting session/transcript 저장
- DevEvent 저장
- timeline API
- daily report 생성/조회/export
- settings API
- dashboard/timeline/report/settings web UI
- Gemini/OpenAI report generation
- provider 실패 또는 key 없음 시 fallback report
- Markdown/PDF export
- local API token 보호 옵션
- sample data/reset/dev check scripts

## 설치

```bash
cd backend
uv sync
```

## 실행

```bash
cd backend
uv run alembic upgrade head
uv run uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload
```

확인:

```bash
curl http://127.0.0.1:8765/health
curl http://127.0.0.1:8765/status
```

웹 화면:

- http://127.0.0.1:8765/dashboard
- http://127.0.0.1:8765/timeline
- http://127.0.0.1:8765/timeline/detail
- http://127.0.0.1:8765/reports
- http://127.0.0.1:8765/settings

## 환경변수

`backend/.env.example`을 참고해 `backend/.env`를 만들 수 있습니다. 실제 `.env`는 git에 포함하지 않습니다.

주요 설정:

- `APP_NAME`: FastAPI 앱 이름
- `APP_VERSION`: 앱 버전
- `APP_HOST`: 기본 `127.0.0.1`
- `APP_PORT`: 기본 `8765`
- `DATABASE_URL`: 기본 `sqlite:///./data/mwoham.sqlite3`
- `AI_PROVIDER`: 개발용 provider override, `gemini` 또는 `openai`
- `AI_MODEL`: 개발용 공통 모델 override
- `GEMINI_API_KEY`, `GEMINI_MODEL`
- `OPENAI_API_KEY`, `OPENAI_MODEL`
- `GEMINI_MAX_OUTPUT_TOKENS`
- `AI_REPORT_TIMEOUT_SECONDS`
- `ENABLE_SCREEN_OBSERVATION_AI_INFERENCE`: 기본 `false`
- `SCREEN_AI_MIN_INTERVAL_SECONDS`
- `SCREEN_AI_DAILY_LIMIT`
- `LOCAL_API_TOKEN`: 설정 시 보호 API에 Bearer token 필요
- `REPORT_EXPORT_DIR`

macOS Release 앱에서는 AI Provider/API Key를 앱 설정에서 관리하고 Keychain에 저장합니다. `.env`는 로컬 개발/수동 backend 실행용 override입니다.

## API 구조

대표 endpoint:

- `GET /health`
- `GET /status`
- `POST /recording/start`
- `POST /recording/pause`
- `POST /recording/resume`
- `POST /recording/stop`
- `POST /events`
- `POST /activity-segments`
- `POST /screen-observations`
- `POST /memos`
- `POST /meetings`
- `POST /meeting-transcripts`
- `GET /timeline/today`
- `GET /timeline/today/detail`
- `POST /reports/daily`
- `GET /reports`
- `GET /reports/today`
- `POST /reports/{report_id}/export`
- `GET /reports/{report_id}/download`
- `POST /dev-events`
- `GET /dev-events/today`
- `GET/PATCH /settings`

`LOCAL_API_TOKEN`이 설정된 경우 POST/PATCH/DELETE 중심 보호 API에는 다음 헤더가 필요합니다.

```bash
Authorization: Bearer $LOCAL_API_TOKEN
```

`GET /health`와 `GET /status`는 공개 상태 확인 endpoint입니다.

## Timeline / Report

Timeline은 WorkEvent, ActivitySegment, ScreenObservation, ManualMemo, MeetingTranscript, DevEvent, Report를 시간 기준으로 조합합니다.

Report 생성 흐름:

1. timeline/report context 수집
2. DevEvent/command flow 압축
3. 현재 Git change hint/diff context를 prompt 전용으로 구성
4. Gemini 또는 OpenAI 호출
5. 응답 cleaning
6. 실패/key 없음/quota/timeout 시 fallback report 생성
7. Markdown/PDF export 가능

정책:

- raw git diff는 DB, DevEvent, log, `Report.content`에 저장하지 않습니다.
- prompt context에 제한적으로만 사용합니다.
- provider가 없어도 fallback report로 기능이 유지됩니다.
- 같은 날짜/모드/project 조합의 daily report는 반복 QA 중 무한히 쌓이지 않도록 기존 row를 갱신할 수 있습니다.

## Meeting Transcript

backend는 오디오 파일을 받지 않습니다. macOS 앱이 Apple Speech 또는 Local Whisper 결과 text만 `/meeting-transcripts` API로 전송합니다.

지원 source:

- `apple_speech`
- `apple_speech_microphone`
- `apple_speech_system_audio`
- `apple_speech_full_meeting`
- `local_whisper_full_meeting`
- `manual`

원본 오디오, raw audio buffer, Local Whisper 임시 파일은 backend에 저장하지 않습니다.

## DevEvent / Dev Tracking

DevEvent는 개발 작업 근거를 저장합니다.

저장 대상:

- Git snapshot summary
- command result metadata
- dev check result
- watcher 기반 Git 상태 변화

저장하지 않는 대상:

- raw git diff
- 파일 내용
- stdout/stderr 전체
- shell history
- 키 입력 내용

주요 명령:

```bash
cd backend
uv run python scripts/run_dev_checks.py --no-record
uv run python scripts/run_dev_checks.py
uv run python scripts/collect_git_snapshot.py --repo-path ..
uv run python scripts/collect_dev_context.py --repo-path ..
uv run python scripts/watch_dev_context.py --repo-path .. --interval 60
uv run python scripts/install_command_tracking_hook.py
uv run python scripts/uninstall_command_tracking_hook.py
```

자세한 정책은 [Dev Tracking](../docs/DEV_TRACKING.md)과 [Command Tracking](../docs/COMMAND_TRACKING.md)을 참고하세요.

## Migration

```bash
cd backend
uv run alembic upgrade head
uv run alembic revision --autogenerate -m "message"
uv run alembic check
```

모델 변경이 없으면 migration을 만들지 않습니다.

## 테스트와 린트

```bash
cd backend
uv run ruff check .
uv run pytest
uv run alembic check
git diff --check
uv run python scripts/run_dev_checks.py --no-record
```

coverage:

```bash
uv run pytest --cov=app --cov-report=term-missing --cov-report=html
```

문서 작업만 하더라도 최소 `run_dev_checks.py --no-record`와 `pytest -q`를 실행해 기존 동작이 깨지지 않았는지 확인합니다.

## 샘플/초기화

샘플 데이터:

```bash
cd backend
uv run python scripts/seed_sample_data.py
uv run python scripts/seed_sample_data.py --reset
```

개발 데이터 초기화:

```bash
cd backend
uv run python scripts/reset_dev_data.py --today
uv run python scripts/reset_dev_data.py --today --yes
uv run python scripts/reset_dev_data.py --all --yes
```

`--yes`가 없으면 dry-run입니다.

## WeasyPrint PDF 의존성

PDF export에서 `libgobject`, `pango` 관련 오류가 나면 macOS에 네이티브 의존성이 필요할 수 있습니다.

```bash
brew install glib pango
```

## 관련 문서

- [Root README](../README.md)
- [macOS Client README](../mac-client/README.md)
- [Tester Install Guide](../docs/TESTER_INSTALL_GUIDE.md)
- [QA Checklist](../docs/QA_CHECKLIST.md)
- [Release Checklist](../docs/RELEASE_CHECKLIST.md)
