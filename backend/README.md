# Mwoham Backend

Mwoham Backend는 로컬 작업 기록 에이전트의 FastAPI 서버입니다. SQLite에 작업 기록을 저장하고, TimelineBuilder와 Gemini 요약을 통해 일일 업무 리포트를 생성합니다.

## 기술 스택

- FastAPI
- SQLAlchemy ORM
- Alembic
- SQLite
- Jinja2 Templates
- WeasyPrint
- uv
- pytest, ruff

## 구조

```text
backend/
  app/
    ai/                 Gemini client, prompt builder, report cleaner
    api/endpoints/      JSON API routers
    core/               config, security, exceptions
    db/                 SQLAlchemy session, DB init
    models/             SQLAlchemy models
    report/             Markdown/PDF export
    repositories/       DB access layer
    schemas/            Pydantic schemas
    services/           business logic
    web/                Jinja2 web routes and templates
  alembic/              migrations
  scripts/              development scripts
  tests/                pytest suite
```

라우팅 원칙은 `router -> service -> repository`입니다. 라우터에는 DB 쿼리를 직접 작성하지 않습니다.

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
```

웹 화면:

- http://127.0.0.1:8765/dashboard
- http://127.0.0.1:8765/timeline
- http://127.0.0.1:8765/reports
- http://127.0.0.1:8765/settings

## 환경변수

`backend/.env.example`을 참고해 `backend/.env`를 만들 수 있습니다. 실제 `.env`는 git에 포함하지 않습니다.

```env
APP_NAME="Mwoham Backend"
APP_VERSION="0.1.0"
APP_HOST="127.0.0.1"
APP_PORT="8765"
DATABASE_URL="sqlite:///./data/mwoham.sqlite3"
GEMINI_API_KEY=""
GEMINI_MODEL="gemini-2.5-flash-lite"
GEMINI_MAX_OUTPUT_TOKENS="8192"
ENABLE_SCREEN_OBSERVATION_AI_INFERENCE="false"
SCREEN_AI_MIN_INTERVAL_SECONDS="300"
SCREEN_AI_DAILY_LIMIT="5"
REPORT_EXPORT_DIR="exports/reports"
LOCAL_API_TOKEN=""
```

- `GEMINI_API_KEY`: Gemini API 키입니다. 비어 있으면 Gemini 호출 없이 placeholder 리포트를 생성합니다.
- `GEMINI_MODEL`: 사용할 Gemini 모델명입니다.
- `GEMINI_MAX_OUTPUT_TOKENS`: Gemini 리포트 생성 응답의 최대 토큰 수입니다.
- `ENABLE_SCREEN_OBSERVATION_AI_INFERENCE`: 개별 화면 관찰 저장 시 Gemini 해석 호출 여부입니다. 기본값은 `false`입니다.
- `SCREEN_AI_MIN_INTERVAL_SECONDS`: 같은 앱/창에서 화면 관찰 AI 해석을 다시 호출하기 전 최소 간격입니다.
- `SCREEN_AI_DAILY_LIMIT`: 화면 관찰 AI 해석의 일일 호출 제한입니다.
- `LOCAL_API_TOKEN`: 설정하면 보호 API에 Bearer 토큰 인증이 필요합니다.
- `REPORT_EXPORT_DIR`: Markdown/PDF export 파일 저장 경로입니다.

## QA 체크리스트

2차 MVP 실사용 검증 절차는 [QA_CHECKLIST.md](../docs/QA_CHECKLIST.md)를 참고하세요.

Xcode 없이 지인 테스트용 앱을 실행하는 절차는 [TESTER_INSTALL_GUIDE.md](../docs/TESTER_INSTALL_GUIDE.md)를 참고하세요.

## Migration

```bash
cd backend
uv run alembic revision --autogenerate -m "message"
uv run alembic upgrade head
uv run alembic check
```

모델 변경이 없는 작업에서는 migration을 만들지 않습니다.

## 테스트와 린트

```bash
cd backend
uv run ruff check .
uv run pytest
uv run alembic check
git diff --check
```

## 샘플 데이터

리포트 품질을 확인하기 위한 샘플 데이터를 생성할 수 있습니다.

```bash
cd backend
uv run python scripts/seed_sample_data.py
uv run python scripts/seed_sample_data.py --reset
```

`--reset`은 이전 샘플 데이터를 지우고 다시 생성합니다.

## 개발/테스트 데이터 초기화

로컬 개발 중 쌓인 기록 데이터를 정리할 수 있습니다. 운영용 기능이 아니라 개발/테스트용 스크립트이며, 기본 실행은 dry-run입니다. 실제 삭제는 반드시 `--yes`를 붙여야 합니다.

```bash
cd backend
uv run python scripts/reset_dev_data.py --today
uv run python scripts/reset_dev_data.py --today --yes
uv run python scripts/reset_dev_data.py --reports-only --yes
uv run python scripts/reset_dev_data.py --observations-only --yes
uv run python scripts/reset_dev_data.py --activity-only --yes
uv run python scripts/reset_dev_data.py --memos-only --yes
uv run python scripts/reset_dev_data.py --events-only --yes
uv run python scripts/reset_dev_data.py --all --yes
```

- `--today`: 오늘 KST 기준 기록 데이터만 대상으로 합니다.
- `--all`: 전체 기록 데이터를 대상으로 합니다.
- `--reports-only`, `--observations-only`, `--activity-only`, `--memos-only`, `--events-only`: 특정 테이블만 대상으로 합니다.
- `--yes`가 없으면 삭제 대상과 개수만 출력하고 실제 삭제하지 않습니다.

## 리포트 생성과 다운로드 확인

1. 서버 실행
2. 샘플 데이터 생성
3. 브라우저에서 http://127.0.0.1:8765/reports 접속
4. `오늘 리포트 생성` 클릭
5. 상세 화면에서 `Markdown 내보내기` 또는 `PDF 내보내기` 클릭

API로 확인:

```bash
curl -X POST http://127.0.0.1:8765/reports/daily
curl -X POST http://127.0.0.1:8765/reports/1/export \
  -H "Content-Type: application/json" \
  -d '{"export_format":"pdf"}'
curl -OJ "http://127.0.0.1:8765/reports/1/download?format=pdf"
```

`LOCAL_API_TOKEN`이 설정되어 있으면 보호 API 호출에 헤더를 추가합니다.

```bash
curl -X POST http://127.0.0.1:8765/reports/daily \
  -H "Authorization: Bearer $LOCAL_API_TOKEN"
```

## WeasyPrint PDF 의존성

PDF export는 WeasyPrint를 사용합니다. macOS에서 네이티브 라이브러리가 없으면 PDF 생성 시 `libgobject`, `pango` 관련 오류가 날 수 있습니다.

Homebrew 환경에서는 다음 설치가 필요할 수 있습니다.

```bash
brew install glib pango
```

## Git 제외 대상

다음은 로컬 산출물이므로 git에 포함하지 않습니다.

- `backend/.env`
- `backend/.venv/`
- `backend/data/`
- `backend/exports/`
- SQLite DB 파일
- 캐시 파일
