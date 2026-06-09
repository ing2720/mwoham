# 자동 Dev Tracking

이 문서는 v0.6 기준 자동 Dev Tracking 구현을 정리합니다. Dev Tracking은 개발 중 Git 상태 변화를 DevEvent로 저장해 일일 리포트의 개발 작업 근거로 사용합니다.

## 전체 흐름

1. macOS 앱이 활성 앱을 감지합니다.
2. 활성 앱이 개발 도구이면 backend watcher process를 자동 시작합니다.
3. watcher가 지정된 repo의 Git 상태를 주기적으로 확인합니다.
4. Git 상태 signature가 바뀌고 debounce 기간 동안 안정되면 DevEvent를 저장합니다.
5. 같은 signature는 persistent state와 TTL 정책으로 중복 저장하지 않습니다.
6. 일일 리포트 생성 시 자동 watcher 이벤트는 20분 버킷과 branch 기준으로 압축됩니다.

사용자가 직접 Dev Tracking 시작/종료 버튼을 누르는 방식은 아닙니다.

웹에서는 `/dashboard`의 최근 개발 이벤트 요약과 `/timeline`/`/timeline/detail`에서 자동 Git
tracking 이벤트를 확인할 수 있습니다. Dashboard는 inspection/setup/cleanup terminal command를
과하게 직접 노출하지 않고, 오늘 작업 리뷰에 필요한 DevEvent 요약을 우선 보여줍니다.

## macOS 앱 자동 실행 정책

개발 도구로 판단하는 앱:

- PyCharm
- Visual Studio Code
- Code
- Terminal
- iTerm
- iTerm2
- Cursor

정책:

- 개발 도구 활성화 시 watcher가 꺼져 있으면 자동 시작합니다.
- watcher가 이미 실행 중이면 중복 실행하지 않습니다.
- 비개발 앱으로 이동하면 바로 종료하지 않고 grace period 후 종료합니다.
- 다시 개발 도구로 돌아오면 종료 예약을 취소합니다.
- 앱 종료 시 child process를 종료합니다.
- stdout/stderr를 읽어 메인 창, 메뉴바, 플로팅 위젯의 Dev Tracking 상태에 반영합니다.

상태 예:

- `Dev Tracking: 감시 시작`
- `Dev Tracking: 변경 없음`
- `Dev Tracking: 변경 감지, 안정화 대기 중`
- `Dev Tracking: Git 변경 감지: ...`
- `Dev Tracking 오류: ...`

## Process 실행 방식

macOS 앱은 backend 디렉터리에서 watcher를 실행합니다.

```bash
uv run python scripts/watch_dev_context.py --repo-path <repo> --interval 60 --session-current
```

앱 실행 환경에는 다음 값을 보강합니다.

- `PATH`: Homebrew, system binary 경로 포함
- `UV_CACHE_DIR`: 기본값 `/private/tmp/mwoham-uv-cache`
- `PYTHONUNBUFFERED=1`: stdout/stderr 실시간 표시용

## Repo path 설정

앱은 추적 repo path 1개만 지원합니다.

- 저장 키: `UserDefaults`의 `devTrackingRepoPath`
- 값이 비어 있으면 현재 mwoham repo fallback 사용
- 여러 repo 지원 없음
- repo 자동 추정 없음
- 수동 시작/종료 버튼 없음

유효성 검사는 다음 순서로 수행합니다.

1. path 존재 여부
2. 디렉터리 여부
3. `git -C <repoPath> rev-parse --show-toplevel` 성공 여부

Git worktree처럼 `.git`이 디렉터리가 아닌 경우도 `rev-parse`가 성공하면 유효한 repo로 봅니다.

## Watcher CLI

기본 실행:

```bash
cd backend
uv run python scripts/watch_dev_context.py --repo-path ..
```

옵션:

```bash
uv run python scripts/watch_dev_context.py --repo-path .. --interval 60
uv run python scripts/watch_dev_context.py --repo-path .. --session-current
uv run python scripts/watch_dev_context.py --repo-path .. --once
uv run python scripts/watch_dev_context.py --repo-path .. --state-path /tmp/mwoham-dev-tracking-state.json
uv run python scripts/watch_dev_context.py --repo-path .. --dedupe-ttl-seconds 21600
uv run python scripts/watch_dev_context.py --repo-path .. --debounce-seconds 20
```

`--once`는 1회 확인 후 종료합니다. 기본적으로 `--once`에서는 debounce를 0초로 처리해 스모크 테스트가 오래 걸리지 않게 합니다.

## Git 상태 signature

signature는 다음 정보를 기반으로 생성합니다.

- branch
- head commit
- ignore policy 적용 후 정렬된 `git status --short`

DevEvent details에는 다음 정보를 함께 저장합니다.

- `tracking_mode="watch"`
- `tracking_signature`
- `head_commit`
- `dirty`
- `changed_files`
- `diff_summary`
- `git_status_summary`
- `git_status_short`

파일 내용과 raw diff 본문은 저장하지 않습니다.

## Ignore policy

자동 추적 signature와 changed files 요약에서 editor/cache/temp 파일을 제외합니다.

- `*.swp`
- `*.swo`
- `.*.swp`
- `.*.swo`
- `*~`
- `.DS_Store`
- `__pycache__/`
- `.pytest_cache/`
- `.coverage`
- `coverage.xml`
- `htmlcov/`

모든 변경이 ignore 대상이면 새 DevEvent를 저장하지 않습니다.

## Persistent state

기본 state path는 Python `tempfile.gettempdir()` 기준입니다.

- macOS: 시스템 temp dir
- Linux CI: `/tmp`
- 파일명: `mwoham-dev-tracking-state.json`

override:

- 환경변수 `MWOHAM_DEV_TRACKING_STATE_PATH`
- CLI 옵션 `--state-path`

state에는 다음만 저장합니다.

- repo key
- signature
- updated_at

state에는 파일 내용, raw diff, changed_files 목록을 저장하지 않습니다.

## Dedupe / debounce

- dedupe TTL 기본값: 21600초, 6시간
- debounce 기본값: 20초
- `--once` 기본 debounce: 0초

동작:

1. 변경 signature 감지
2. debounce 기간 동안 같은 signature가 유지되는지 확인
3. 안정화되면 DevEvent 저장
4. 같은 repo key와 signature가 TTL 안에 다시 감지되면 저장 생략
5. TTL이 지나면 같은 signature도 다시 저장 가능

## diff_summary

자동 watcher DevEvent는 안전한 diff stat 수준의 메타데이터를 저장합니다.

저장 예:

```json
{
  "file": "backend/scripts/dev_tracking.py",
  "insertions": 120,
  "deletions": 20,
  "status": "unstaged"
}
```

정책:

- `git diff --numstat HEAD` 기반
- 파일별 insertions/deletions 저장
- binary 파일은 `binary=true`
- untracked 파일은 파일 내용 없이 `untracked=true`
- raw diff 본문 저장 없음
- 코드 라인 저장 없음
- 파일 내용 읽기 없음

## 수동 DevEvent 수집과 차이

수동 작업 마감:

```bash
cd backend
uv run python scripts/collect_dev_context.py --repo-path ..
```

수동 수집은 작업 종료 시 Git snapshot과 개발 검증 결과를 명시적으로 남기는 흐름입니다.

자동 watcher는 개발 도구 활성화 중 Git 상태 변화를 주기적으로 감지해 DevEvent를 남기는 흐름입니다. 두 흐름은 함께 사용할 수 있습니다.

## Report input 반영

자동 watcher 기반 `git_snapshot`은 report input에서 그대로 나열하지 않습니다.

- KST 기준 20분 버킷
- branch 기준 그룹
- `DEV_EVENT_GROUP`으로 압축
- 개별 자동 watcher 이벤트는 priority/work evidence/final dump에서 중복 제외
- 수동 `collect_git_snapshot.py` 기반 `git_snapshot`은 기존 `DEV_EVENT`로 유지

예:

```text
DEV_EVENT_GROUP | time_range=09:00~09:20 | source=watch | branch=feat/... | summary=자동 Dev Tracking: ...
```

## CURRENT_GIT_DIFF_CONTEXT

일일 리포트 생성 시점에는 현재 repo의 git diff를 읽어 prompt context에만 넣습니다.

정책:

- report 생성 시점에만 읽음
- `PrivacyFilter` 적용
- prompt context에만 포함
- DB 저장 없음
- DevEvent 저장 없음
- log 출력 없음
- 최종 `Report.content`에 raw diff를 그대로 쓰지 않도록 prompt에서 지시
- clean working tree면 diff context 없이 기존 DevEvent 기반으로 리포트 생성

제외 대상:

- `.env`, `.env.*`
- `*.pem`, `*.key`, `*.p12`
- `*.sqlite3`, `*.db`
- `node_modules/`
- `.venv/`, `venv/`
- `__pycache__/`, `.pytest_cache/`
- `DerivedData/`
- `build/`, `dist/`, `htmlcov/`
- 이미지, 음성, 영상 바이너리 파일
- 긴 lock 파일

## CURRENT_GIT_CHANGE_HINTS

`CURRENT_GIT_DIFF_CONTEXT`와 함께 기능 단위 힌트를 생성합니다.

힌트는 파일 경로, diff hunk header, 짧은 함수/옵션/키워드 토큰을 기반으로 생성합니다. 코드 원문을 길게 복사하지 않고, report가 구체 기능명을 쓰도록 돕는 prompt 전용 요약입니다.

예:

- `backend/scripts/dev_tracking.py: Dev Tracking persistent state, TTL dedupe, debounce 안정화 관련 변경`
- `mac-client/MwohamMac/MwohamMac/DevTrackingProcessController.swift: watcher stdout/stderr 상태 표시, repo path 설정/검증 관련 변경`
- `backend/app/ai/prompt_builder.py: report input 20분 압축, CURRENT_GIT_DIFF_CONTEXT 우선순위 관련 변경`

## 현재 한계

- 여러 repo 지원 없음
- repo 자동 추정 없음
- LaunchAgent/daemon 없음
- 수동 시작/종료 버튼 없음

## 후속 작업 후보

- 여러 repo 지원
- repo 자동 추정
- Dev Tracking LaunchAgent/daemon 여부 검토
- report 품질 고도화
- PromptBuilder 분리 리팩토링
- Swift Dev Tracking 상태 문자열 추가 공통화
