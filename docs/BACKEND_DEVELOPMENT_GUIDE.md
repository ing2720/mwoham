# Backend Development Guide

이 문서는 Mwoham Backend를 새 환경에서 실행하고 개발할 때 필요한 기준 명령과 운영 원칙을 정리합니다.

## 프로젝트 소개

Mwoham Backend는 개인 작업 기록을 로컬 SQLite DB에 저장하고, 타임라인을 구성한 뒤 Gemini로 일일 업무 리포트를 생성하는 로컬 백엔드입니다.

주요 기능:

- 기록 세션 제어
- 이벤트, 메모, 화면 OCR, 회의, 전사 저장
- TimelineBuilder 기반 일일 타임라인 생성
- Gemini 리포트 생성과 후처리
- Markdown/PDF export와 다운로드
- 로컬 웹 대시보드
- 설정과 기록 제외 앱 관리
- Local API Bearer 토큰 인증

## 현재 구조

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
- Swift 코드는 백엔드 작업 범위에서 만들지 않습니다.

## 설치

```bash
cd backend
uv sync
```

## 환경 설정

`backend/.env.example`을 참고해 `backend/.env`를 만듭니다. 실제 `.env`는 git에 포함하지 않습니다.

설정값:

- `DATABASE_URL`: DB URL입니다. 기본값은 `sqlite:///./data/mwoham.sqlite3`입니다.
- `GEMINI_API_KEY`: Gemini API 키입니다. 비어 있으면 Gemini 호출 없이 fallback/placeholder 리포트를 생성합니다.
- `GEMINI_MODEL`: Gemini 모델명입니다.
- `GEMINI_MAX_OUTPUT_TOKENS`: Gemini 응답 최대 토큰 수입니다. 기본값은 `8192`입니다.
- `LOCAL_API_TOKEN`: 설정하면 보호 API에 `Authorization: Bearer <token>`이 필요합니다.
- `REPORT_EXPORT_DIR`: Markdown/PDF export 저장 경로입니다.

주의:

- `.env`는 만들거나 수정한 뒤 git에 포함하지 않습니다.
- `backend/data/`, `backend/exports/`, SQLite DB 파일은 git에 포함하지 않습니다.

## 실행

```bash
cd backend
uv run alembic upgrade head
uv run uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload
```

상태 확인:

```bash
curl http://127.0.0.1:8765/health
curl http://127.0.0.1:8765/status
```

웹:

- 대시보드: http://127.0.0.1:8765/dashboard
- 타임라인: http://127.0.0.1:8765/timeline
- 리포트: http://127.0.0.1:8765/reports
- 설정: http://127.0.0.1:8765/settings

## Alembic

현재 DB 반영:

```bash
uv run alembic upgrade head
```

모델 변경 후 migration 생성:

```bash
uv run alembic revision --autogenerate -m "message"
```

모델과 migration 일치 확인:

```bash
uv run alembic check
```

## 테스트

```bash
cd backend
uv run pytest
```

특정 테스트:

```bash
uv run pytest tests/test_report_api.py
```

실제 Gemini 호출은 자동 테스트에서 수행하지 않습니다. Gemini 관련 테스트는 mock, unconfigured fallback, parser 단위 테스트 중심으로 작성합니다.

## Ruff

```bash
cd backend
uv run ruff check .
```

필요할 때만 자동 수정:

```bash
uv run ruff check . --fix
```

## 샘플 데이터 생성

리포트 품질을 수동 입력 없이 확인하려면 샘플 데이터를 생성합니다.

```bash
cd backend
uv run python scripts/seed_sample_data.py
```

중복 샘플 데이터를 정리하고 다시 만들려면:

```bash
uv run python scripts/seed_sample_data.py --reset
```

생성되는 데이터:

- WorkSession
- WorkEvent: Chrome 문서 확인, VSCode 코드 수정, Terminal 테스트 실패/성공
- ManualMemo
- ScreenObservation: OCR 텍스트와 감지 키워드 포함
- MeetingSession
- VoiceTranscript

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
  -d '{"export_format":"markdown"}'
curl -OJ "http://127.0.0.1:8765/reports/1/download?format=markdown"
```

PDF:

```bash
curl -X POST http://127.0.0.1:8765/reports/1/export \
  -H "Content-Type: application/json" \
  -d '{"export_format":"pdf"}'
curl -OJ "http://127.0.0.1:8765/reports/1/download?format=pdf"
```

## Local API Bearer 토큰

`LOCAL_API_TOKEN`이 비어 있으면 개발 편의상 보호 API도 인증 없이 통과합니다.

`LOCAL_API_TOKEN`이 설정되어 있으면 POST/PATCH/DELETE 중심 보호 API에 Bearer 토큰이 필요합니다.

```bash
curl -X POST http://127.0.0.1:8765/recording/start \
  -H "Authorization: Bearer $LOCAL_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'
```

공개 API:

- `GET /health`
- `GET /status`

로컬 웹 대시보드는 같은 백엔드에서 렌더링되며 service를 직접 호출하므로 기존 사용성이 유지됩니다.

## WeasyPrint PDF 의존성

PDF 생성은 WeasyPrint를 사용합니다. macOS에서 다음 네이티브 의존성이 필요할 수 있습니다.

```bash
brew install glib pango
```

증상:

- `libgobject-2.0` 로드 실패
- `pango` 관련 import 실패

이 경우 Homebrew 설치 후 다시 PDF export를 시도합니다.

## 검증 루틴

작업 완료 전 기본 검증:

```bash
cd backend
uv run ruff check .
uv run pytest
uv run alembic check
git diff --check
```
