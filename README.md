# Mwoham

Mwoham은 macOS 기반 개인 업무 기록/요약 앱입니다. macOS 앱이 작업 흐름을 수집하고, 로컬 FastAPI backend가 SQLite에 저장한 뒤 Gemini를 이용해 일일 리포트를 생성합니다.

현재 구현은 macOS SwiftUI 클라이언트와 FastAPI 로컬 서버 기반입니다. 일반 창, 메뉴바, 플로팅 위젯, Daily Review Dashboard, 기본/상세 타임라인, Markdown/PDF 리포트 export를 제공합니다.

## 현재 기능

- 기록 세션 제어: 시작, 일시정지, 재개, 종료
- 활성 앱/창 메타데이터 기반 작업 구간 저장
- PrivateApp 제외 정책
- 화면 OCR 텍스트 수집
- 빠른 메모 저장
- MeetingSession과 MeetingTranscript 저장
- Apple Speech 기반 회의 전사
  - 마이크
  - 시스템 오디오
  - 회의 전체
- DevEvent 저장
  - Git snapshot
  - 개발 검증 명령 결과
  - 자동 Dev Tracking watcher
  - zsh hook 기반 터미널 명령 metadata
- Gemini 기반 일일 리포트 생성
- Daily Review Dashboard
  - 오늘 Daily Report 카드
  - validation command 중심 검증 결과
  - failed→success command 흐름
  - 최근 개발 이벤트 요약
  - 회의/메모 요약
- Markdown/PDF export와 브라우저 다운로드
- 개발/테스트 데이터 초기화
- Local API Bearer 토큰 인증

## 구조

```text
backend/
  FastAPI, SQLite, TimelineBuilder, Gemini report, web dashboard
mac-client/MwohamMac/
  macOS SwiftUI app, menu bar, floating widget, OCR, meeting transcription, Dev Tracking process
docs/
  QA, tester guide, Dev Tracking, system audio transcription notes
```

## 빠른 시작

```bash
cd backend
uv sync
uv run alembic upgrade head
uv run uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload
```

브라우저에서 확인:

- Daily Review Dashboard: http://127.0.0.1:8765/dashboard
- 기본 타임라인: http://127.0.0.1:8765/timeline
- 상세 타임라인: http://127.0.0.1:8765/timeline/detail
- 리포트: http://127.0.0.1:8765/reports
- 설정: http://127.0.0.1:8765/settings

macOS 앱은 Xcode에서 실행하거나, 내부 테스트용 Release 앱 번들을 받아 실행합니다. 현재 테스트 배포는 backend를 앱에 번들링하지 않으므로 backend는 별도로 실행해야 합니다.

개발 중 macOS 권한을 안정적으로 유지하려면 고정 경로의 `MwohamMac.app` bundle을 사용합니다:

```bash
mkdir -p ~/.config/mwoham
cat > ~/.config/mwoham/macos-signing.env <<'EOF'
MWOHAM_DEVELOPMENT_TEAM=YOUR_TEAM_ID
EOF

./scripts/build_macos_app.sh --open
```

Team ID는 인증서 표시 이름 끝의 괄호 값이 아니라 인증서 subject의 `OU` 또는
서명 앱의 `TeamIdentifier`입니다. 스크립트는 해당 Team ID의 Apple Development
인증서를 찾아 SHA-1 fingerprint로 정확히 지정합니다. 인증서가 여러 개이면
`MWOHAM_CODE_SIGN_IDENTITY`에 `security find-identity`가 출력한 전체 이름을
선택적으로 설정할 수 있습니다.

화면 기록, 마이크, 음성 인식 등 macOS 권한은 이 스크립트가 여는 고정 앱 번들인
`~/Applications/MwohamMac.app` 기준으로 부여합니다.

`build_macos_app.sh`는 `com.ing2720.MwohamMac` bundle identifier, Apple
Development 서명, 설정된 Team ID를 검증합니다. 인증서가 없거나 ad-hoc
서명으로 생성된 앱은 TCC identity가 빌드마다 달라질 수 있으므로 실행하지
않습니다. 빠른 UI 확인이나 CI는 `--unsigned` 또는 `--unsigned --open`으로
실행할 수 있지만 권한 유지 용도로 사용하지 않습니다. signed 실패 시 unsigned로
자동 전환되지 않습니다.

macOS 접근성, 화면 기록, 마이크 권한은 앱이 자동 허용할 수 없습니다. 최초 설치
또는 기존 ad-hoc 앱에서 서명된 앱으로 전환한 뒤 시스템 설정에서 고정 경로의
앱을 다시 허용해야 합니다.

## 환경 설정

백엔드는 `backend/.env`를 읽습니다. 실제 `.env`는 git에 포함하지 않습니다. 예시는 [backend/.env.example](backend/.env.example)을 참고하세요.

주요 설정:

- `DATABASE_URL`: 기본값 `sqlite:///./data/mwoham.sqlite3`
- `GEMINI_API_KEY`: Gemini API 키. 비어 있으면 system fallback 리포트를 생성할 수 있습니다.
- `GEMINI_MODEL`: 기본값 `gemini-2.5-flash-lite`
- `GEMINI_MAX_OUTPUT_TOKENS`: Gemini 리포트 최대 출력 토큰
- `ENABLE_SCREEN_OBSERVATION_AI_INFERENCE`: 개별 화면 관찰 AI 해석 호출 여부. 기본값은 `false`
- `SCREEN_AI_MIN_INTERVAL_SECONDS`: 화면 관찰 AI 해석 최소 간격
- `SCREEN_AI_DAILY_LIMIT`: 화면 관찰 AI 해석 일일 제한
- `LOCAL_API_TOKEN`: 설정 시 보호 API에 `Authorization: Bearer <token>` 필요
- `REPORT_EXPORT_DIR`: 리포트 export 저장 경로

## 개발 검증

로컬 검증만 실행하고 DevEvent를 저장하지 않으려면:

```bash
cd backend
uv run python scripts/run_dev_checks.py --no-record
```

개별 검증:

```bash
cd backend
uv run ruff check .
uv run pytest
uv run alembic check
git diff --check
```

coverage 확인:

```bash
cd backend
uv run pytest --cov=app --cov-report=term-missing --cov-report=html
```

작업 마감 시 Git snapshot과 검증 결과를 DevEvent로 남기려면:

```bash
cd backend
uv run python scripts/collect_dev_context.py --repo-path ..
```

## Dev Tracking

v0.6 기준으로 macOS 앱은 개발 도구가 활성화되면 backend watcher process를 자동 실행합니다. 사용자가 직접 시작/종료 버튼을 누르는 방식은 아닙니다.

자동 실행 대상 앱:

- PyCharm
- Visual Studio Code
- Code
- Terminal
- iTerm
- iTerm2
- Cursor

앱은 설정된 repo path 1개를 추적합니다. 설정값이 비어 있으면 현재 mwoham repo fallback을 사용하고, repo 검증은 `git rev-parse --show-toplevel` 기준으로 수행합니다.

자세한 정책은 [Dev Tracking](docs/DEV_TRACKING.md)을 참고하세요.

## Timeline Filtering

v0.8 기준으로 웹 타임라인은 최신 항목이 위에 오도록 표시합니다. 이 정렬은 웹 표시용 context에만
적용됩니다. Timeline API(`/timeline/today`, `/timeline/today/detail`)와 daily report 입력용
timeline은 기존 시간순 흐름을 유지합니다.

웹 타임라인은 `filter` query parameter로 항목을 좁혀 볼 수 있습니다.

```text
/timeline?filter=all
/timeline?filter=command
/timeline?filter=command_failed
/timeline?date=2026-06-08&filter=git
```

지원 필터:

- `all`: 전체
- `dev`: DevEvent 전체
- `git`: 자동 Git tracking 이벤트
- `command`: 터미널 command_result 전체
- `command_failed`: 실패한 터미널 명령 확인용
- `meeting`: 회의 전사
- `memo`: 수동 메모
- `report`: 일일 리포트

알 수 없는 filter 값은 `all`로 처리합니다. `date`와 `filter` query는 함께 사용할 수 있습니다.

## Daily Review Dashboard

v1.0 기준 `/dashboard`는 오늘 작업을 한 화면에서 검수하는 Daily Review Dashboard 역할을 합니다.
별도 `/review/today`, `/daily-review` 화면은 공식 기능이 아니며, 기존 대시보드에 리뷰 섹션을
통합했습니다.

확인 가능한 내용:

- 오늘 생성된 Daily Report 카드: 제목, 생성 시각, 짧은 preview, 상세 링크
- validation command 중심 검증 결과: pytest, run_dev_checks, alembic check, git diff check, ruff, xcodebuild 등
- failed→success command 흐름
- 최근 개발 이벤트와 자동 Git tracking 요약
- 회의/메모 요약
- 기존 현재 상태, 오늘 요약, 이벤트 입력, 메모 입력, 최근 타임라인

inspection/setup/cleanup terminal command는 dashboard에서 과하게 직접 노출하지 않고, 필요한 경우
검증 흐름이나 최근 타임라인의 보조 맥락으로만 다룹니다. 기존 timeline과 reports 화면은
dashboard에서 이어서 확인할 수 있습니다.

## Command Tracking

v0.7 기준으로 zsh hook 기반 터미널 명령 자동 기록을 지원합니다. 설치하면 `preexec`와
`precmd` hook이 명령 metadata를 수집해 `command_result` DevEvent로 저장합니다.

```bash
cd backend
uv run python scripts/install_command_tracking_hook.py
```

설치 후 새 터미널부터 자동 적용됩니다. 현재 열려 있는 터미널에서는 다음 명령으로 적용합니다.

```bash
source ~/.zshrc
```

상태 확인과 현재 터미널 비활성화:

```bash
mwoham_command_tracking_status
mwoham_command_tracking_disable
```

해제:

```bash
cd backend
uv run python scripts/uninstall_command_tracking_hook.py
```

저장 대상은 `command`, `exit_code`, `duration_ms`, `cwd`, `repo_path`, `branch` 같은
metadata입니다. stdout/stderr 전체, shell history, 키 입력 내용은 저장하지 않으며
민감정보는 마스킹합니다. failed command는 리포트에서 우선 근거로 다루고,
`sqlite3`, `curl`, `echo`, `source` 같은 확인용 command는 낮은 우선순위로 참고합니다.
타임라인에는 `명령 성공` 또는 `명령 실패` label로 표시됩니다.

자세한 정책은 [Command Tracking](docs/COMMAND_TRACKING.md)을 참고하세요.

## Report Quality

v0.9 기준 daily report는 detailed report 품질 개선에 집중합니다. summary/simple/compact
요약본 분리는 아직 공식 기능이 아닙니다.

리포트 입력은 현재 작업 주제를 먼저 잡기 위해 `CURRENT_WORK_FOCUS`를 우선 반영합니다.
`command_result`는 `PRIORITY_COMMAND_FLOWS`에서 `failed_to_success`, `failed_only`,
`development_validation`, `inspection`, `cleanup` 흐름으로 구분해 전달합니다.

report 작성 정책:

- failed command는 실제 장애로 과장하지 않고 주변 DevEvent, diff context, command 흐름과 함께 해석
- inspection/setup command는 보조 근거로만 사용
- cleanup command는 명령 원문을 길게 나열하지 않고 간결하게 요약
- meeting transcript는 결정사항, 논의사항, 후속작업 후보로 나눠 반영하되 근거 없이 결정사항을 만들지 않음
- 이미 완료된 기능은 다음 작업 후보로 반복 제안하지 않도록 prompt에서 지시
- raw diff는 저장하지 않고 report 생성 시 prompt context에만 제한적으로 사용
- stdout/stderr 전체, shell history, 키 입력 내용은 저장하지 않음

남은 후속 후보는 report input pruning, event relevance scoring, QA/noise event tagging,
meeting transcript report quality, daily review dashboard refinement입니다.

## Privacy / Safety

Mwoham의 현재 구현 원칙:

- 원본 화면 이미지 저장 없음
- OCR용 캡처 이미지를 backend로 전송하지 않음
- 원본 오디오 파일 저장 없음
- raw audio buffer 저장 없음
- backend로 audio data 전송 없음
- 전사 text만 `/meeting-transcripts` API로 저장
- terminal command tracking은 stdout/stderr 전체, shell history, 키 입력 내용을 저장하지 않음
- raw git diff를 DB, DevEvent, log, Report.content에 저장하지 않음
- report 생성 시 제한된 git diff context만 prompt context로 일시 사용
- token, password, secret, api_key, bearer, authorization 계열 문자열은 PrivacyFilter로 마스킹

## 문서

- [Backend README](backend/README.md)
- [macOS Client README](mac-client/README.md)
- [Development Guide](DEVELOPMENT.md)
- [Backend Development Guide](docs/BACKEND_DEVELOPMENT_GUIDE.md)
- [Dev Tracking](docs/DEV_TRACKING.md)
- [Command Tracking](docs/COMMAND_TRACKING.md)
- [System Audio Capture/Transcription](docs/SYSTEM_AUDIO_CAPTURE_SPIKE.md)
- [QA Checklist](docs/QA_CHECKLIST.md)
- [Tester Install Guide](docs/TESTER_INSTALL_GUIDE.md)
- [Codex Workflow](docs/CODEX_WORKFLOW.md)

## CI

- Backend CI는 ruff, pytest, coverage, alembic, git diff check를 검증합니다.
- macOS client CI는 `MwohamMac`의 `xcodebuild build`만 검증합니다.
- 화면 기록 권한, OCR 수집, Speech/마이크 권한, 메뉴바/플로팅 동작은 macOS 권한과 실제 사용자 세션이 필요하므로 수동 QA에서 검증합니다.

## Git 제외 대상

다음은 로컬 산출물이므로 git에 포함하지 않습니다.

- `backend/.env`
- `backend/.venv/`
- `backend/data/`
- `backend/exports/`
- SQLite DB 파일
- `dist/`
- coverage 산출물
- 캐시 파일
