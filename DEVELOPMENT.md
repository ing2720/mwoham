# Development Guide

이 문서는 공개 저장소에 포함해도 되는 Mwoham Backend 개발/실행 가이드입니다. 기획서, 시트, Codex 작업 노트 등 내부 문서는 `docs/`에 보관하며 git에는 포함하지 않습니다.

## 프로젝트 소개

Mwoham Backend는 개인 작업 기록을 로컬 SQLite DB에 저장하고, 타임라인을 구성한 뒤 Gemini로 일일 업무 리포트를 생성하는 FastAPI 백엔드입니다.

주요 기능:

- 기록 세션 제어
- 이벤트, 메모, 화면 OCR, 회의, 전사 저장
- TimelineBuilder 기반 일일 타임라인 생성
- Gemini 리포트 생성과 후처리
- Markdown/PDF export와 다운로드
- 로컬 웹 대시보드
- 설정과 기록 제외 앱 관리
- Local API Bearer 토큰 인증

## 구조

```text
backend/app/
  ai/             Gemini client, prompt builder, summarizer, report cleaner
  api/endpoints/  FastAPI JSON API endpoint
  core/           config, security, exception
  db/             database session and initialization
  models/         SQLAlchemy models
  report/         Markdown/PDF export
  repositories/   database access
  schemas/        Pydantic request/response schemas
  services/       business logic
  web/            Jinja2 web routes and templates
```

원칙:

- `router -> service -> repository` 흐름을 유지합니다.
- 라우터에 DB 쿼리를 직접 작성하지 않습니다.
- 모델 변경이 없으면 migration을 만들지 않습니다.

## 설치

```bash
cd backend
uv sync
```

## 환경 설정

`backend/.env.example`을 참고해 `backend/.env`를 만듭니다. 실제 `.env`는 git에 포함하지 않습니다.

주요 설정:

- `DATABASE_URL`: 기본값 `sqlite:///./data/mwoham.sqlite3`
- `GEMINI_API_KEY`: Gemini API 키. 비어 있으면 fallback/placeholder 리포트를 생성합니다.
- `GEMINI_MODEL`: Gemini 모델명
- `GEMINI_MAX_OUTPUT_TOKENS`: Gemini 응답 최대 토큰 수. 기본값 `8192`
- `LOCAL_API_TOKEN`: 설정하면 보호 API에 `Authorization: Bearer <token>` 필요
- `REPORT_EXPORT_DIR`: Markdown/PDF export 저장 경로

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

웹:

- http://127.0.0.1:8765/dashboard
- http://127.0.0.1:8765/timeline
- http://127.0.0.1:8765/reports
- http://127.0.0.1:8765/settings

## Alembic

```bash
cd backend
uv run alembic upgrade head
uv run alembic revision --autogenerate -m "message"
uv run alembic check
```

## 테스트와 린트

```bash
cd backend
uv run ruff check .
uv run pytest
uv run alembic check
git diff --check
```

## 샘플 데이터

```bash
cd backend
uv run python scripts/seed_sample_data.py
uv run python scripts/seed_sample_data.py --reset
```

`--reset`은 이전 샘플 데이터를 지우고 다시 생성합니다.

## 리포트 생성과 다운로드

웹에서 확인:

1. 서버 실행
2. 샘플 데이터 생성
3. http://127.0.0.1:8765/reports 접속
4. `오늘 리포트 생성` 클릭
5. 상세 화면에서 Markdown/PDF 다운로드

API에서 확인:

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

PDF export는 WeasyPrint를 사용합니다. macOS에서 네이티브 라이브러리가 없으면 `libgobject`, `pango` 관련 오류가 날 수 있습니다.

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
- `docs/`
- 캐시 파일
