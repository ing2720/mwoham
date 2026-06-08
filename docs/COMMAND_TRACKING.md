# 터미널 명령 자동 기록

이 문서는 v0.7 기준 zsh 명령 자동 기록 설치와 저장 정책을 정리합니다.

## 목표

터미널에서 실행한 개발 명령 metadata를 DevEvent로 저장해 일일 리포트가 실패/성공 흐름을 더 잘 반영하게 합니다.

저장 대상:

- command
- exit_code
- duration_ms
- cwd
- repo_path
- branch
- started_at
- ended_at
- success / failed
- shell
- session_current 여부

저장하지 않는 대상:

- stdout 전체
- stderr 전체
- 터미널 출력 전문
- 환경변수 전체
- 파일 내용
- raw git diff
- shell history 전체
- 키 입력 감시 또는 키 입력 내용

## 설치

```bash
cd backend
uv run python scripts/install_command_tracking_hook.py
```

설치 스크립트는 `~/.zshrc`에 다음 source line을 추가합니다.

```zsh
source "<repo>/backend/scripts/mwoham_zsh_tracking.zsh"
```

중복 설치는 하지 않습니다. 설치 후 새 터미널부터 자동 적용됩니다.

현재 열려 있는 터미널에서 바로 적용하려면 다음 명령을 실행합니다.

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

## 해제

```bash
cd backend
uv run python scripts/uninstall_command_tracking_hook.py
```

해제 스크립트는 설치된 source line을 제거합니다.

이미 열려 있는 zsh에는 hook이 남아 있을 수 있습니다. 현재 터미널에서 즉시 끄려면 다음 명령을
실행합니다.

```bash
mwoham_command_tracking_disable
```

## zsh hook 동작

`backend/scripts/mwoham_zsh_tracking.zsh`는 zsh의 `preexec`와 `precmd` hook을 사용합니다.

- `preexec`: 명령 문자열, cwd, 시작 시각 저장
- `precmd`: 직전 명령 exit code, 종료 시각, duration 계산 후 DevEvent 저장 스크립트 호출

hook은 다음 명령으로 DevEvent를 저장합니다.

```bash
uv run python scripts/record_command_result.py \
  --command "<command>" \
  --exit-code "<exit_code>" \
  --duration-ms "<duration_ms>" \
  --cwd "<cwd>" \
  --started-at "<started_at>" \
  --ended-at "<ended_at>" \
  --shell "zsh" \
  --source "terminal" \
  --session-current
```

hook 실패는 사용자 명령 실행을 막지 않도록 조용히 처리합니다.

hook은 stdout/stderr 전체를 읽거나 저장하지 않습니다. shell history 전체를 읽지 않고, 사용자의
키 입력을 감시하지 않습니다.

## 저장 정책

`record_command_result.py`는 command metadata를 `DevEvent`로 저장합니다.

- `event_type`: `command_result`
- `source`: `terminal`
- `status`: exit code 0이면 `success`, 아니면 `failed`
- `summary`: `명령 성공: ...` 또는 `명령 실패: ... exit_code=...`
- `details_json.tracking_mode`: `command_hook`

주요 metadata는 `command`, `exit_code`, `duration_ms`, `cwd`, `repo_path`, `branch`입니다.

cwd가 Git repo 안이면 다음 값을 함께 저장합니다.

- `repo_path`: `git rev-parse --show-toplevel`
- `branch`: `git branch --show-current` 또는 `git rev-parse --abbrev-ref HEAD`

Git repo가 아니면 `repo_path`와 `branch`는 비워둘 수 있습니다.

## 제외 명령

노이즈와 재귀 기록을 줄이기 위해 다음 명령은 저장하지 않습니다.

- 빈 명령
- `cd`
- `pwd`
- `ls`
- `clear`
- `record_command_result.py` 자체 호출
- command tracking hook 설치/해제 명령
- `.env` 파일을 읽는 `cat`, `less`, `more`, `tail`, `head`, `sed`, `awk`, `grep`, `rg` 계열 명령

## 민감정보 마스킹

command, summary, details_json에는 PrivacyFilter를 적용합니다.

마스킹 대상 예:

- token
- password
- passwd
- secret
- api_key
- apikey
- bearer
- authorization
- access_key
- refresh_token

긴 command는 저장 전 500자 이하로 줄입니다.

## Report 반영

terminal command DevEvent는 report input의 `PRIORITY_DEV_EVENTS`에 포함됩니다.

정책:

- 실패한 terminal command를 성공 command보다 우선 근거로 배치합니다.
- 실패 후 성공한 같은 계열 명령은 하나의 해결 흐름으로 요약하도록 prompt에서 지시합니다.
- `sqlite3`, `curl`, `echo`, `source ~/.zshrc` 같은 확인용 inspection command는 report에서 낮은 우선순위로 참고합니다.
- 터미널 출력 전문은 없으므로 실패 원인은 command, exit_code, 주변 DevEvent, CURRENT_GIT_DIFF_CONTEXT 근거가 있을 때만 보수적으로 판단합니다.

## Timeline 표시

terminal command 기반 `command_result` DevEvent는 timeline에서 상태에 따라 다음 label로 표시됩니다.

- 성공: `명령 성공`
- 실패: `명령 실패`

## 현재 한계

- zsh만 지원합니다.
- bash/fish 통합은 없습니다.
- 터미널 출력 전문은 저장하지 않습니다.
- shell history 전체를 읽지 않습니다.
- 키 입력 감시를 하지 않습니다.
- LaunchAgent/daemon은 없습니다.
