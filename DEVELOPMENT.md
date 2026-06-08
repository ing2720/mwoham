# Development Guide

이 문서는 공개 저장소에 포함해도 되는 Mwoham 개발/실행 가이드입니다.

## 프로젝트 소개

Mwoham은 macOS에서 개인 작업 기록을 수집하고, 로컬 backend에서 타임라인과 일일 리포트로 정리하는 앱입니다.

구성:

- macOS SwiftUI 앱: 기록 제어, OCR, 회의 전사, 자동 Dev Tracking process 실행, 메뉴바/플로팅 위젯
- FastAPI backend: SQLite 저장, timeline/report 생성, Gemini 호출, Markdown/PDF export, 웹 대시보드

주요 기능:

- 기록 세션 제어
- 이벤트, 메모, 화면 OCR, 회의, 전사, DevEvent 저장
- TimelineBuilder 기반 일일 타임라인 생성
- Gemini 리포트 생성과 후처리
- Markdown/PDF export와 다운로드
- 로컬 웹 대시보드
- 설정과 기록 제외 앱 관리
- Local API Bearer 토큰 인증
- Apple Speech 기반 마이크/시스템 오디오/회의 전체 전사
- 자동 Dev Tracking watcher

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

macOS 앱:

```text
mac-client/MwohamMac/MwohamMac/
  ContentView.swift
  LocalApiClient.swift
  MeetingTranscriptionViewModel.swift
  AppleSpeechTranscriptionProvider.swift
  SystemAudioSpeechTranscriptionProvider.swift
  FullMeetingSpeechTranscriptionProvider.swift
  DevTrackingProcessController.swift
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
- `ENABLE_SCREEN_OBSERVATION_AI_INFERENCE`: 개별 화면 관찰 AI 해석 호출 여부. 기본값은 `false`
- `SCREEN_AI_MIN_INTERVAL_SECONDS`: 화면 관찰 AI 해석 최소 간격
- `SCREEN_AI_DAILY_LIMIT`: 화면 관찰 AI 해석 일일 제한

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
uv run python scripts/run_dev_checks.py --no-record
git diff --check
```

coverage:

```bash
cd backend
uv run pytest --cov=app --cov-report=term-missing --cov-report=html
```

macOS 앱 빌드:

```bash
xcodebuild \
  -project mac-client/MwohamMac/MwohamMac.xcodeproj \
  -scheme MwohamMac \
  -destination platform=macOS \
  -derivedDataPath /tmp/MwohamMacDerivedData \
  build
```

## DevEvent와 자동 Dev Tracking

작업 마감 시 DevEvent를 수동 수집할 수 있습니다.

```bash
cd backend
uv run python scripts/collect_dev_context.py --repo-path ..
```

자동 Dev Tracking watcher는 macOS 앱이 개발 도구 활성화를 감지했을 때 실행합니다.

```bash
cd backend
uv run python scripts/watch_dev_context.py --repo-path .. --interval 60 --session-current
```

정책:

- Git 상태 signature 변경 시 DevEvent 저장
- temp/swap/cache 파일 제외
- persistent state와 6시간 TTL dedupe
- 20초 debounce
- diff_summary 저장
- raw diff 본문과 파일 내용 저장 없음

자세한 내용은 [docs/DEV_TRACKING.md](docs/DEV_TRACKING.md)를 참고하세요.

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

리포트 생성 시 자동 watcher `git_snapshot`은 20분 버킷과 branch 기준으로 압축됩니다. 현재 Git diff는 report prompt context에만 제한적으로 포함되며 DB, DevEvent, log, Report.content에는 raw diff를 저장하지 않습니다.

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
