# Mwoham Backend

Mwoham Backend는 로컬 작업 기록 에이전트의 FastAPI 서버입니다. SQLite에 작업 기록을 저장하고, TimelineBuilder와 Gemini 요약을 통해 일일 업무 리포트를 생성합니다.

macOS 앱은 backend API를 통해 기록 세션, 활성 앱/창 구간, OCR 텍스트, 수동 메모, 회의 전사, DevEvent를 저장합니다. backend는 Daily Review Dashboard, 기본/상세 타임라인, Markdown/PDF export, 개발용 스크립트를 제공합니다.

개발 중 macOS 권한을 안정적으로 유지하려면 repo root에서 고정 앱 번들을 실행합니다.

```bash
./scripts/build_macos_app.sh --open
```

화면 기록, 마이크, 음성 인식 등 앱 권한은 `~/Applications/MwohamMac.app` 기준으로 부여합니다.

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
- http://127.0.0.1:8765/timeline/detail
- http://127.0.0.1:8765/reports
- http://127.0.0.1:8765/settings

`/dashboard`는 오늘 작업 리뷰 화면입니다. 별도 `/review/today`, `/daily-review` route는
공식 기능이 아니며, 오늘 작업 상태와 리뷰 섹션은 기존 dashboard에 통합되어 있습니다.

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

실사용 검증 절차는 [QA_CHECKLIST.md](../docs/QA_CHECKLIST.md)를 참고하세요.

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

로컬 개발 검증만 실행하고 DevEvent를 저장하지 않으려면:

```bash
cd backend
uv run python scripts/run_dev_checks.py --no-record
```

coverage 확인:

```bash
cd backend
uv run pytest --cov=app --cov-report=term-missing --cov-report=html
```

현재 coverage threshold는 적용하지 않습니다. 핵심 service 테스트를 더 보강한 뒤 도입합니다.

## 주요 개발 스크립트

```bash
cd backend
uv run python scripts/run_dev_checks.py --no-record
uv run python scripts/run_dev_checks.py
uv run python scripts/collect_git_snapshot.py --repo-path ..
uv run python scripts/record_command_result.py --command "uv run pytest" --status success --summary "pytest 통과" --event-type test_result
uv run python scripts/collect_dev_context.py --repo-path ..
uv run python scripts/watch_dev_context.py --repo-path .. --interval 60
uv run python scripts/install_command_tracking_hook.py
uv run python scripts/uninstall_command_tracking_hook.py
```

- `run_dev_checks.py --no-record`: ruff, pytest, alembic, git diff check를 실행하고 DevEvent는 저장하지 않습니다.
- `run_dev_checks.py`: 같은 검증을 실행하고 각 결과를 DevEvent로 저장합니다.
- `collect_git_snapshot.py`: branch, git status, changed files, diff stat, recent commits를 DevEvent로 저장합니다. Git diff 본문은 저장하지 않습니다.
- `record_command_result.py`: 개발 명령 결과를 summary 중심으로 DevEvent에 저장합니다.
- `collect_dev_context.py`: Git snapshot 수집 후 dev checks를 실행해 작업 마감용 DevEvent를 남깁니다.
- `watch_dev_context.py`: Git 상태를 주기적으로 감지해 변경 시 DevEvent를 저장합니다.
- `install_command_tracking_hook.py`: zsh command tracking hook source line을 `~/.zshrc`에 설치합니다.
- `uninstall_command_tracking_hook.py`: zsh command tracking hook source line을 `~/.zshrc`에서 제거합니다.

터미널 명령 자동 기록 설치/해제와 저장 정책은 [Command Tracking 문서](../docs/COMMAND_TRACKING.md)를 참고하세요.

## zsh Command Tracking

v0.7 command tracking은 zsh `preexec`/`precmd` hook 기반입니다. hook은 사용자 명령의
metadata를 `record_command_result.py`로 전달하고, backend는 이를 `command_result`
DevEvent로 저장합니다.

설치:

```bash
cd backend
uv run python scripts/install_command_tracking_hook.py
```

설치 후 새 터미널부터 자동 적용됩니다. 현재 터미널에서 바로 쓰려면 다음 명령을 실행합니다.

```bash
source ~/.zshrc
```

상태 확인:

```bash
mwoham_command_tracking_status
```

현재 터미널에서만 비활성화:

```bash
mwoham_command_tracking_disable
```

해제:

```bash
cd backend
uv run python scripts/uninstall_command_tracking_hook.py
```

저장되는 command metadata:

- `command`
- `exit_code`
- `duration_ms`
- `cwd`
- `repo_path`
- `branch`

저장하지 않는 항목:

- stdout/stderr 전체
- shell history
- 키 입력 내용
- 파일 내용
- raw git diff

command, summary, details에는 `PrivacyFilter`가 적용되어 민감정보를 마스킹합니다.
터미널 명령은 웹 타임라인에서 `명령 성공` 또는 `명령 실패` label로 표시됩니다.

## Daily Review Dashboard

`/dashboard`는 오늘 작업 상태를 한 화면에서 검수하는 Daily Review Dashboard 역할을 합니다.
기존 dashboard의 현재 상태, 오늘 요약, 이벤트 입력, 메모 입력, 최근 타임라인은 유지하고,
다음 리뷰 섹션을 함께 표시합니다.

- 오늘 Daily Report 카드: 제목, 생성 시각, 짧은 preview, 상세 링크
- 검증 결과: validation command 중심 표시
- 실패 후 성공 흐름: failed command 이후 success command가 확인된 흐름
- 최근 개발 이벤트 요약: DevEvent와 자동 Git tracking 요약
- 회의/메모 요약

validation command는 pytest, `run_dev_checks.py`, alembic check, `git diff --check`, ruff,
xcodebuild, `bash -n`, `zsh -n` 같은 검증 명령을 우선 표시합니다. `sqlite3`, `curl`,
`echo`, `source`, `git switch`, `git pull`, cleanup command 같은 inspection/setup/cleanup
terminal command는 dashboard에 과하게 직접 노출하지 않습니다.

기존 timeline과 reports 화면은 `/dashboard`에서 이어서 확인합니다. 이 작업은 웹 표시 확장이며
DB schema, migration, JSON API, Swift/mac-client, report prompt/input pruning, command hook,
Dev Tracking watcher를 변경하지 않습니다.

## Timeline Filtering

웹 타임라인(`/timeline`, `/timeline/detail`)은 사용자가 최근 작업을 먼저 확인할 수 있도록 최신
항목을 위에 표시합니다. 이 정렬은 웹 표시용 context에만 적용되며, Timeline API와 report input은
기존 시간순 정렬을 유지합니다.

API/report 정렬 정책:

- `/timeline/today`: 기존 시간순 ASC 유지
- `/timeline/today/detail`: 기존 시간순 ASC 유지
- daily report input: 시간 흐름 이해를 위해 기존 시간순 유지

웹 타임라인 필터는 `filter` query parameter를 사용합니다. `date` query와 함께 사용할 수 있고,
알 수 없는 filter 값은 `all`로 fallback합니다.

예:

```text
/timeline?filter=all
/timeline?filter=command
/timeline?filter=command_failed
/timeline?date=2026-06-08&filter=git
```

지원 필터:

- `all`: 전체
- `dev`: DevEvent 전체
- `git`: 자동 Git tracking 이벤트 확인용
- `command`: terminal `command_result` 전체
- `command_failed`: 실패한 터미널 명령 확인용
- `meeting`: 회의 전사
- `memo`: 수동 메모
- `report`: 일일 리포트

## DevEvent 작업 마감 수집

작업 종료 시 Git 상태와 개발 검증 결과를 DevEvent로 저장한 뒤 일일 리포트를 생성합니다.

```bash
cd backend
uv run python scripts/collect_dev_context.py
uv run python scripts/collect_dev_context.py --repo-path ..
uv run python scripts/collect_dev_context.py --session-current
```

권장 흐름:

1. 로컬 검증만 필요하면 `run_dev_checks.py --no-record` 실행
2. 검증 결과를 DevEvent로 남기려면 `run_dev_checks.py` 실행
3. 작업 종료 시 `collect_dev_context.py --repo-path ..` 실행
4. 브라우저 또는 API에서 `/reports/daily` 생성

## 자동 Dev Tracking watcher

`watch_dev_context.py`는 v0.6 자동 Dev Tracking의 backend watcher입니다.

```bash
cd backend
uv run python scripts/watch_dev_context.py --repo-path ..
uv run python scripts/watch_dev_context.py --repo-path .. --interval 60
uv run python scripts/watch_dev_context.py --repo-path .. --session-current
uv run python scripts/watch_dev_context.py --repo-path .. --once
uv run python scripts/watch_dev_context.py --repo-path .. --state-path /tmp/mwoham-dev-tracking-state.json
```

정책:

- Git 상태 signature가 바뀌었을 때만 DevEvent를 저장합니다.
- signature는 branch, head commit, ignore policy 적용 후 `git status --short` 기준입니다.
- Vim swap, editor temp, cache, coverage 산출물은 변경 감지 대상에서 제외합니다.
- persistent state에는 repo key, signature, updated_at만 저장합니다.
- state에는 파일 내용, raw diff, changed_files 목록을 저장하지 않습니다.
- dedupe TTL 기본값은 6시간입니다.
- debounce 기본값은 20초입니다.
- `--once`는 기본 debounce 0초로 1회 확인 후 종료합니다.
- `--state-path`와 `MWOHAM_DEV_TRACKING_STATE_PATH` override를 지원합니다.
- `diff_summary`에는 파일별 insertions/deletions, binary 여부, untracked 여부 같은 안전한 메타데이터만 저장합니다.
- raw diff 본문과 파일 내용은 DevEvent, DB, log에 저장하지 않습니다.

자세한 내용은 [Dev Tracking 문서](../docs/DEV_TRACKING.md)를 참고하세요.

## DevEvent API

DevEvent는 Git snapshot, 개발 명령 결과, 자동 watcher 이벤트, terminal command 결과를 저장하는 개발 작업 근거입니다.

주요 API:

- `POST /dev-events`
- `GET /dev-events`
- `GET /dev-events/today`

`POST /dev-events`는 Local API Token 보호 대상입니다. `LOCAL_API_TOKEN`을 설정한 경우 `Authorization: Bearer <token>` 헤더가 필요합니다.

자동 watcher 기반 `git_snapshot`은 웹 타임라인에서는 DevEvent로 확인할 수 있고, report input에서는 20분 버킷과 branch 기준으로 압축됩니다. 수동 `collect_git_snapshot.py` 이벤트는 기존 DevEvent로 유지됩니다. terminal command 기반 `command_result`는 웹 타임라인에서 `명령 성공` 또는 `명령 실패` label로 확인할 수 있습니다.

## Report input과 Report Quality

일일 리포트 생성 시 PromptBuilder는 timeline 데이터를 압축해 Gemini prompt를 만듭니다.
v0.9 기준 report quality 개선은 detailed report 중심입니다. summary/simple/compact 요약본
분리는 아직 공식 기능이 아닙니다.

우선순위:

1. `CURRENT_WORK_FOCUS`
2. `PRIORITY_CURRENT_GIT_CHANGE_HINTS`
3. `PRIORITY_CURRENT_GIT_DIFF_CONTEXT`
4. 수동 메모
5. `PRIORITY_DEV_EVENTS`
6. `PRIORITY_COMMAND_FLOWS`
7. 회의 전사
8. 화면 관찰
9. 작업 환경 요약

자동 watcher 기반 `git_snapshot`은 다음 정책으로 압축합니다.

- KST 기준 20분 버킷
- branch 기준 그룹
- `DEV_EVENT_GROUP`으로 report input에 포함
- 개별 자동 watcher 이벤트는 priority/work evidence/final dump에서 중복 제외

`CURRENT_GIT_DIFF_CONTEXT`는 report 생성 시점에만 현재 repo의 git diff를 읽어 prompt context에 넣습니다.

- `PrivacyFilter` 적용
- DB 저장 없음
- DevEvent 저장 없음
- log 출력 없음
- 최종 `Report.content`에 raw diff를 그대로 쓰지 않도록 prompt에서 지시
- clean working tree면 diff context 없이 기존 DevEvent 기반으로 리포트 생성

`CURRENT_GIT_CHANGE_HINTS`는 diff에서 기능 단위 힌트를 추출합니다. 예를 들어 persistent state, TTL dedupe, debounce, repo path 설정, stdout/stderr 상태 표시 같은 구체 기능명이 리포트에 반영되도록 돕습니다.

`CURRENT_WORK_FOCUS`는 `CURRENT_GIT_CHANGE_HINTS`, `CURRENT_GIT_DIFF_CONTEXT`, 현재 변경 파일,
command flow를 보고 최신 작업 주제를 짧게 요약합니다. report는 하루 전체 이벤트를 보더라도
이 최신 작업 주제를 먼저 반영하도록 지시합니다.

terminal command 기반 `command_result`는 `PRIORITY_DEV_EVENTS`와 `PRIORITY_COMMAND_FLOWS`에
포함됩니다. `PRIORITY_COMMAND_FLOWS`는 다음 흐름을 구분합니다.

- `failed_to_success`: 같은 계열 command가 실패 후 성공한 검증 흐름
- `failed_only`: 아직 이어지는 성공 command가 확인되지 않은 실패 흐름
- `development_validation`: pytest, run_dev_checks, alembic check, git diff check, ruff, xcodebuild 같은 개발 검증 흐름
- `inspection`: sqlite3, curl, echo, source, command tracking status/disable 같은 확인용 흐름
- `cleanup`: rm -rf 같은 cleanup 흐름

failed command는 실제 장애로 과장하지 않고 command, exit_code, 주변 DevEvent, diff context를
함께 보고 보수적으로 해석합니다. inspection/setup command는 report 본문을 지배하지 않도록
보조 근거로만 사용하고, cleanup command는 명령 원문을 길게 나열하지 않고 간결하게 요약하도록
prompt에서 지시합니다.

회의 전사는 결정사항, 논의사항, 후속작업 후보로 나눠 반영하도록 instruction을 보강했습니다.
의미 없는 전사나 OCR/전사 노이즈는 확정 사실처럼 쓰지 않도록 지시합니다.

다음 작업 후보는 이미 완료/검증/문서화된 기능을 반복 제안하지 않고 현재 작업의 자연스러운
후속 단계만 3~5개 정도 제안하도록 지시합니다.

후속 개선 후보:

- report input pruning
- event relevance scoring
- QA/noise event tagging
- meeting transcript report quality
- daily review dashboard refinement

## Meeting Transcript

회의 전사는 원본 오디오 파일이나 raw audio buffer를 저장하지 않습니다. Mac 앱은 전사된 text만 기존 `/meeting-transcripts` API로 전송하고, backend는 transcript text와 source 값을 저장합니다.

현재 transcript source 값은 다음 입력 경로를 구분합니다.

- `apple_speech`: 기존 Apple Speech 기본값
- `apple_speech_microphone`: 마이크 단독 전사
- `apple_speech_system_audio`: 시스템 오디오 단독 전사
- `apple_speech_full_meeting`: 마이크와 시스템 오디오를 하나의 Apple Speech recognitionTask로 처리한 회의 전체 전사
- `local_whisper_full_meeting`: 회의 전체 임시 WAV를 local Whisper로 처리한 최종 전사
- `manual`: 수동 입력 transcript

Local Whisper 연결에서도 DB schema, migration, API endpoint는 변경하지 않았습니다.
Mac 앱은 임시 WAV를 로컬에서 처리 후 삭제하며 backend에는 transcript text만 전송합니다.

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
uv run python scripts/reset_dev_data.py --except-today --yes
uv run python scripts/reset_dev_data.py --reports-only --yes
uv run python scripts/reset_dev_data.py --dev-events-only --yes
uv run python scripts/reset_dev_data.py --transcripts-only --yes
uv run python scripts/reset_dev_data.py --meetings-only --yes
uv run python scripts/reset_dev_data.py --observations-only --yes
uv run python scripts/reset_dev_data.py --activity-only --yes
uv run python scripts/reset_dev_data.py --memos-only --yes
uv run python scripts/reset_dev_data.py --events-only --yes
uv run python scripts/reset_dev_data.py --all --yes
```

- `--today`: 오늘 KST 기준 기록 데이터만 대상으로 합니다.
- `--except-today`: 오늘 KST 기준 기록은 남기고 나머지 기록 데이터를 대상으로 합니다.
- `--all`: 전체 기록 데이터를 대상으로 합니다.
- `--reports-only`, `--dev-events-only`, `--transcripts-only`, `--meetings-only`, `--observations-only`, `--activity-only`, `--memos-only`, `--events-only`: 특정 테이블만 대상으로 합니다.
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
