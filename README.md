# mwoham

뭐함은 macOS에서 사용자의 작업 흐름을 로컬에 기록하고, Gemini를 이용해 일일 업무 리포트로 정리하는 개인용 작업 기록 에이전트입니다.

현재 구현 범위는 백엔드 중심입니다. FastAPI, SQLAlchemy, Alembic, SQLite, Jinja2 Templates 기반으로 로컬 API와 웹 대시보드를 제공합니다.

## 현재 기능

- 기록 세션 제어: 시작, 일시정지, 재개, 종료
- 작업 이벤트, 수동 메모, 화면 OCR 관찰, 회의 세션, 회의 전사 저장
- 오늘 타임라인 생성
- Gemini 기반 일일 리포트 생성
- Markdown/PDF export와 브라우저 다운로드
- 로컬 웹 대시보드
- 설정과 기록 제외 앱 관리
- Local API Bearer 토큰 인증
- 개발용 샘플 데이터 생성 스크립트

## 빠른 시작

```bash
cd backend
uv sync
uv run alembic upgrade head
uv run uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload
```

브라우저에서 확인:

- 대시보드: http://127.0.0.1:8765/dashboard
- 타임라인: http://127.0.0.1:8765/timeline
- 리포트: http://127.0.0.1:8765/reports
- 설정: http://127.0.0.1:8765/settings

## 환경 설정

백엔드는 `backend/.env`를 읽습니다. 실제 `.env`는 git에 포함하지 않습니다. 예시는 [backend/.env.example](backend/.env.example)을 참고하세요.

주요 설정:

- `DATABASE_URL`: 기본값 `sqlite:///./data/mwoham.sqlite3`
- `GEMINI_API_KEY`: Gemini API 키. 비어 있으면 placeholder 리포트를 생성합니다.
- `GEMINI_MODEL`: Gemini 모델명
- `GEMINI_MAX_OUTPUT_TOKENS`: Gemini 리포트 최대 출력 토큰
- `LOCAL_API_TOKEN`: 설정 시 보호 API에 `Authorization: Bearer <token>` 필요
- `REPORT_EXPORT_DIR`: 리포트 export 저장 경로

## 개발 명령

```bash
cd backend
uv run ruff check .
uv run pytest
uv run alembic check
git diff --check
```

샘플 데이터 생성:

```bash
cd backend
uv run python scripts/seed_sample_data.py --reset
```

## 문서

- [Backend README](backend/README.md)
- [Backend Development Guide](docs/BACKEND_DEVELOPMENT_GUIDE.md)
- [Codex Workflow](docs/CODEX_WORKFLOW.md)

## 주의사항

- `.env`, `backend/data/`, `backend/exports/`, SQLite DB 파일은 git에 포함하지 않습니다.
- Swift 코드는 아직 이 저장소 범위에서 구현하지 않습니다.
- 실제 Gemini 호출 테스트는 수동 확인이 필요할 때만 수행하고, 자동 테스트에서는 mock/fallback 중심으로 검증합니다.
