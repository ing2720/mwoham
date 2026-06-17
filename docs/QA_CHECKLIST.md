# MVP QA 체크리스트

이 문서는 MVP를 실제 사용 시나리오 기준으로 검증하기 위한 체크리스트입니다.
기능 구현 문서가 아니라, 로컬 환경에서 무엇을 확인해야 하는지와 실패 시 의심 원인을 정리합니다.

## 사전 준비

- macOS 앱과 백엔드는 같은 머신에서 실행합니다.
- 백엔드는 `http://127.0.0.1:8765`에서 실행합니다.
- 화면 OCR 검증 전 macOS 화면 기록 권한을 허용합니다.
- 회의 전사 검증 전 선택한 source에 맞는 권한을 허용합니다.
  - 마이크: 음성 인식, 마이크
  - 시스템 오디오: 음성 인식, 화면 기록
  - 회의 전체: 음성 인식, 마이크, 화면 기록
- 실제 Gemini 호출은 quota를 소모합니다. 기본 정책상 개별 ScreenObservation AI 해석은 비활성화되어 있고, 일일 리포트 생성에 Gemini 호출을 우선 사용합니다.
- `LOCAL_API_TOKEN`을 설정한 경우 모든 보호 API 호출에 `Authorization: Bearer <token>` 헤더를 추가합니다.

## 1. 백엔드 실행

macOS 앱 자동 시작 확인:

1. 포트 `8765`를 사용하는 프로세스가 없는 상태에서 signed 앱을 실행합니다.
2. 설정 > 백엔드에서 상태가 `시작 중`을 거쳐 `연결됨`으로 바뀌는지 확인합니다.
3. 프로세스 소유가 `앱이 시작함`으로 표시되는지 확인합니다.
4. `curl http://127.0.0.1:8765/health`가 `200 OK`를 반환하는지 확인합니다.
5. `앱이 띄운 backend 중지`를 누르면 해당 프로세스만 종료되고 상태가
   `중지됨`으로 바뀌는지 확인합니다.

앱은 다음 고정 명령을 인자 배열로 실행합니다.

```bash
cd /Users/a/Projects/mwoham/backend
uv run uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload
```

외부 backend 보존 확인:

1. 아래 수동 명령으로 backend를 먼저 실행합니다.
2. 앱을 실행하고 상태가 `연결됨`, 프로세스 소유가 `외부 실행 또는 없음`으로
   표시되는지 확인합니다.
3. 앱에서 중지/재시작 버튼이 비활성화되고, 앱을 종료해도 수동 backend가
   유지되는지 확인합니다.

명령:

```bash
cd backend
uv sync
uv run alembic upgrade head
uv run uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload
```

확인:

```bash
curl http://127.0.0.1:8765/health
curl http://127.0.0.1:8765/status
```

정상 기대 결과:

- `/health`가 `200 OK`를 반환합니다.
- `/status`가 현재 기록 상태를 반환합니다.
- 브라우저에서 `http://127.0.0.1:8765/dashboard`가 열립니다.
- `/dashboard`가 Daily Review Dashboard 역할을 하며 오늘 작업 리뷰 섹션을 표시합니다.

실패 시 의심 원인:

- 포트 `8765`가 이미 사용 중입니다.
- 포트는 열려 있지만 `/health`가 정상 응답하지 않아 `포트 충돌 의심` 상태입니다.
- `/Users/a/Projects/mwoham/backend` 경로가 없어 `backend 경로 오류` 상태입니다.
- 앱 실행 환경의 `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`에서 `uv`를 찾지
  못해 `uv 실행 실패` 상태입니다.
- `uv sync`가 끝나지 않았거나 가상환경 의존성이 없습니다.
- migration이 적용되지 않았습니다.
- `LOCAL_API_TOKEN` 설정 후 헤더 없이 호출했습니다.

설정 > 백엔드 > backend 진단에서 실행 경로와 최근 stdout/stderr 최대 40줄을
확인합니다. 자동 시작은 앱 실행당 한 번만 시도하며 실패 후 반복 실행하지
않습니다. `backend 다시 확인` 또는 `backend 시작`으로 명시적으로 재시도합니다.

## 2. Daily Review Dashboard 확인

확인:

```bash
open "http://127.0.0.1:8765/dashboard"
```

정상 기대 결과:

- `/dashboard` 한 화면에서 오늘 작업 상태를 검수할 수 있습니다.
- 현재 상태 카드와 오늘 요약이 표시됩니다.
- 오늘 Daily Report가 있으면 제목, 생성 시각, 짧은 preview, 상세 링크가 표시됩니다.
- 오늘 Daily Report가 없으면 빈 상태가 표시됩니다.
- validation command 중심 검증 결과가 표시됩니다.
  - pytest
  - `run_dev_checks.py`
  - alembic check
  - `git diff --check`
  - ruff
  - xcodebuild
  - `bash -n`
  - `zsh -n`
- failed command 이후 success command가 있으면 실패 후 성공 흐름에 표시됩니다.
- `tests/not_exists.py` 같은 QA성 실패는 실제 장애처럼 과장하지 않고 짧게 표시됩니다.
- 최근 개발 이벤트와 자동 Git tracking 요약이 표시됩니다.
- 회의 전사나 수동 메모가 있으면 회의/메모 요약에 표시됩니다.
- 회의/메모가 없으면 `확인된 회의/메모 없음` 빈 상태가 표시됩니다.
- 기존 이벤트 입력 폼, 메모 입력 폼, 최근 타임라인이 유지됩니다.
- timeline과 reports 화면은 기존 링크 또는 내비게이션으로 이어서 확인할 수 있습니다.

정책:

- 별도 `/review/today`, `/daily-review` 화면은 공식 기능이 아닙니다.
- `sqlite3`, `curl`, `echo`, `source`, `git switch`, `git pull` 같은 inspection/setup command는 dashboard에 과하게 직접 노출하지 않습니다.
- cleanup terminal command도 긴 원문 중심으로 노출하지 않습니다.
- 이 화면은 기존 데이터를 보여주는 웹 표시 확장이며 DB, API, Swift/mac-client, report prompt/input pruning, command hook, Dev Tracking watcher를 변경하지 않습니다.

실패 시 의심 원인:

- 오늘 날짜 기준 report나 DevEvent가 아직 생성되지 않았습니다.
- command tracking hook이 설치되지 않았거나 새 터미널에 적용되지 않았습니다.
- validation command가 inspection/setup command로 분류될 수 있는 형태로 실행되었습니다.
- dashboard가 아닌 `/timeline` 또는 `/reports` 화면과 혼동했습니다.

## 3. Mac 앱 실행

개발용 고정 서명 설정:

```bash
security find-identity -v -p codesigning

# 인증서 표시 이름의 괄호가 아닌 subject OU가 실제 Team ID입니다.
security find-certificate \
  -c "Apple Development: YOUR_NAME" \
  -p | openssl x509 -noout -subject

mkdir -p ~/.config/mwoham
cat > ~/.config/mwoham/macos-signing.env <<'EOF'
MWOHAM_DEVELOPMENT_TEAM=YOUR_TEAM_ID
EOF

./scripts/build_macos_app.sh --open
```

패키징 모드:

```bash
# signed Debug: 개발 및 권한/TCC QA
./scripts/build_macos_app.sh --open

# signed Release: 설치 앱 최종 QA 권장
./scripts/build_macos_app.sh --release --open

# unsigned Debug: UI 임시 확인만
./scripts/build_macos_app.sh --unsigned --open

# unsigned Release: 명시적으로 요청한 임시 패키징 확인만
./scripts/build_macos_app.sh --unsigned --release
```

각 실행에서 `Build mode`, `Configuration`, `Bundle ID`, `Team ID`, signing
identity, app output path가 출력되는지 확인합니다. signed 실패 시 unsigned
build가 자동으로 이어지지 않아야 합니다.

다른 Mac 최초 설정:

1. Xcode > Settings > Accounts에 Apple ID를 추가합니다.
2. `Manage Certificates...`에서 Apple Development 인증서를 생성합니다.
3. `security find-identity`로 인증서를 확인합니다.
4. 인증서 subject의 `OU`를 `MWOHAM_DEVELOPMENT_TEAM`에 설정합니다.
5. `build_macos_app.sh --open`으로 고정 경로 signed 앱을 실행합니다.

인증서가 여러 개이면 설정 파일에 다음 값을 선택적으로 추가합니다.

```bash
MWOHAM_CODE_SIGN_IDENTITY="Apple Development: name@example.com (CERTIFICATE_ID)"
```

빠른 UI/CI 확인:

```bash
./scripts/build_macos_app.sh --unsigned
./scripts/build_macos_app.sh --unsigned --open
```

unsigned 모드는 Team ID와 인증서 없이 빌드할 수 있지만 TCC 상태가 안정적으로
유지되지 않습니다. 권한 테스트에는 사용하지 않습니다. signed 빌드가 실패해도
unsigned로 자동 fallback하지 않습니다.

확인:

- 앱 실행 경로가 `~/Applications/MwohamMac.app`인지 확인합니다.
- 일반 창에서 백엔드 연결 상태가 `연결됨`으로 보입니다.
- 메뉴바 항목이 표시됩니다.
- 메뉴바에서 플로팅 위젯을 열고 닫을 수 있습니다.

bundle 및 코드 서명 확인:

```bash
APP="$HOME/Applications/MwohamMac.app"

/usr/libexec/PlistBuddy \
  -c "Print :CFBundleIdentifier" \
  "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 \
  | grep -E "^(Identifier|Authority|TeamIdentifier|Signature)="
codesign -d -r- "$APP" 2>&1
spctl --assess --type execute --verbose=4 "$APP" || true
```

정상 기대 결과:

- Debug/Release bundle identifier가 모두 `com.ing2720.MwohamMac`입니다.
- `Signature=adhoc`이 출력되지 않습니다.
- `Authority=Apple Development: ...`가 표시됩니다.
- `TeamIdentifier`가 `MWOHAM_DEVELOPMENT_TEAM`과 같습니다.
- 앱을 다시 빌드해도 실행 경로와 designated requirement가 유지됩니다.
- 표시 이름이 `MwohamMac`, version/build가 `1.0 (1)`인지 확인합니다.
- Finder와 Dock에서 placeholder 앱 아이콘이 기본 실행 파일 아이콘 대신
  표시되는지 확인합니다.

패키징/업데이트 QA:

1. signed Debug를 설치하고 `~/Applications/MwohamMac.app`에서 실행되는지
   확인합니다.
2. signed Release로 교체한 뒤 실행 경로가 유지되고 기존 앱 프로세스가 새
   bundle로 교체되는지 확인합니다.
3. `codesign --verify --deep --strict`가 통과하고 Identifier, TeamIdentifier,
   Authority가 기대값과 일치하는지 확인합니다.
4. 앱 시작 후 backend lifecycle이 기존 backend를 재사용하거나 필요 시 자동
   시작하는지 확인합니다.
5. 권한 온보딩과 독립 권한 상태 표시가 signed 앱 identity 기준으로 유지되는지
   확인합니다.
6. unsigned 앱은 경고를 출력하고 실행되지만 권한/TCC QA에는 사용하지 않습니다.
7. `--destination`을 지정하지 않은 기본 실행에서 `/Applications`가 아니라
   `~/Applications/MwohamMac.app`을 사용하는지 확인합니다.

`spctl`은 Developer ID/notarization 배포 검사가 포함되므로 Apple Development
내부 빌드에서는 거부될 수 있습니다. 현재 필수 검증은 strict codesign과
Identifier, TeamIdentifier, Authority 일치입니다.

TCC 권한 확인:

- 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서
  `~/Applications/MwohamMac.app`을 허용합니다.
- 화면 기록, 마이크, 음성 인식도 같은 고정 앱 bundle 기준으로 허용합니다.
- 접근성 권한은 앱에서 자동 허용할 수 없습니다.
- 기존 ad-hoc 앱을 사용했다면 목록의 이전 MwohamMac 항목을 제거하고 서명된
  고정 경로 앱을 다시 추가한 뒤 앱을 재실행합니다.

Launch at Login QA:

1. signed 앱을 `~/Applications/MwohamMac.app`에서 실행합니다.
2. 설정 > 자동 실행 카드에 `로그인 시 자동 실행` Toggle과 현재 상태 badge가
   표시되는지 확인합니다.
3. Toggle을 켜면 macOS 로그인 항목에 MwohamMac이 등록되고 상태가 `등록됨`으로
   갱신되는지 확인합니다.
4. Toggle을 끄면 로그인 항목 등록이 해제되고 상태가 `해제됨`으로 갱신되는지
   확인합니다.
5. `상태 새로고침`을 눌렀을 때 실제 ServiceManagement 상태와 badge가
   일치하는지 확인합니다.
6. 시스템 승인이 필요한 경우 `승인 필요` warning이 표시되는지 확인합니다.
7. 등록/해제 실패 시 `자동 실행 설정 실패` ErrorBanner가 표시되는지
   확인합니다.
8. 로그인 자동 실행 후에도 recording이 자동 시작되지 않고 대기 상태로 남는지
   확인합니다.
9. Dev Tracking 자동화 정책, backend lifecycle, 메뉴바 상주 동작이 기존과
   동일한지 확인합니다.
10. harness를 실행해 ServiceManagement wrapper 상태 전환이 통과하는지
    확인합니다.

```bash
./scripts/test_macos_launch_at_login.sh
```

권한 온보딩 확인:

1. 첫 실행 상태로 확인하려면 다음 값을 초기화한 뒤 signed 앱을 실행합니다.

```bash
defaults delete com.ing2720.MwohamMac hasCompletedPermissionOnboarding 2>/dev/null || true
./scripts/build_macos_app.sh --open
```

2. `권한 설정` 화면에 마이크, 음성 인식, 화면 기록, 접근성 상태가 각각
   표시되는지 확인합니다.
3. 마이크, 음성 인식 또는 Local Whisper, backend 연결 중 필수 조건이 부족하면
   `시작 가능` 상태가 표시되지 않는지 확인합니다.
4. 화면 기록이나 접근성 권한만 없으면 warning이 표시되지만 `시작하기`가
   가능한지 확인합니다.
5. 접근성 권한이 없어도 현재 앱/창 정보가 수집되면 `제한됨`으로 표시되고 앱
   사용을 막지 않는지 확인합니다.
6. `권한 상태 다시 확인`을 눌러 현재 TCC와 backend 상태가 갱신되는지 확인합니다.
7. 설정 > 권한에서 `권한 설정 다시 보기`를 눌러 온보딩이 다시 열리는지
   확인합니다.
8. 각 권한의 설정 열기 버튼이 해당 macOS 개인정보 보호 설정 화면으로 이동하는지
   확인합니다. 앱이 권한을 자동 승인하지 않는지 확인합니다.
9. 선택 항목의 `debug audio 저장` Toggle을 켜고 끌 때 설정 > Local Whisper의
   QA/debug WAV 보관 설정과 동기화되는지 확인합니다.
10. `개발 이벤트 추적` Toggle을 끄면 실행 중 watcher가 종료되고 recording을
    시작해도 자동 watcher가 시작되지 않는지 확인합니다.
11. `개발 이벤트 추적` Toggle을 다시 켜면 상태가 `켜짐`으로 표시되고 기존
    수동 Dev Tracking 시작 경로로 watcher 실행을 시도하는지 확인합니다.

실패 시 의심 원인:

- 백엔드가 실행 중이 아닙니다.
- 앱 sandbox/권한 설정 때문에 로컬 API 호출이 막혔습니다.
- `LOCAL_API_TOKEN`이 백엔드에만 설정되어 있고 앱 환경에는 전달되지 않았습니다.
- Xcode 계정에 Apple Development 인증서가 없습니다.
- `MWOHAM_DEVELOPMENT_TEAM`이 실제 인증서 Team ID와 다릅니다.
- 인증서 이름 끝의 괄호 값을 Team ID로 잘못 사용했습니다. 실제 값은 subject의
  `OU`와 `codesign`의 `TeamIdentifier`입니다.
- Xcode Run 또는 DerivedData의 임시 앱에 권한을 부여했습니다.
- `--unsigned` 또는 `CODE_SIGNING_ALLOWED=NO` 빌드를 실행 앱으로 사용했습니다.

## 4. 기록 시작, 일시정지, 재개, 종료

명령:

```bash
curl -X POST http://127.0.0.1:8765/recording/start
curl http://127.0.0.1:8765/status
curl -X POST http://127.0.0.1:8765/recording/pause
curl -X POST http://127.0.0.1:8765/recording/resume
curl -X POST http://127.0.0.1:8765/recording/stop
```

UI 확인:

- Mac 앱의 `기록 시작`, `일시정지`, `재개`, `기록 종료` 버튼이 상태에 맞게 동작합니다.
- 플로팅 위젯의 접힌/펼친 상태에서도 상태와 버튼이 맞게 보입니다.
- 기록 시간이 active 상태에서 갱신됩니다.

정상 기대 결과:

- `status`가 `active -> paused -> active -> stopped` 순서로 변합니다.
- stopped 상태에서는 기록 시간이 `기록 중 아님`으로 보입니다.

실패 시 의심 원인:

- 이미 active 세션이 있어 중복 시작이 거부되었습니다.
- active 세션 없이 pause/resume/stop을 호출했습니다.
- 앱 화면이 갱신되지 않았다면 새로고침을 누릅니다.

## 5. ActivitySegment 저장 확인

절차:

1. 기록을 시작합니다.
2. Chrome, PyCharm, Xcode 등 여러 앱으로 전환합니다.
3. 각 앱/창을 몇 초 이상 유지합니다.

확인 명령:

```bash
curl "http://127.0.0.1:8765/activity-segments?date=$(date +%F)"
curl "http://127.0.0.1:8765/timeline/today/detail?date=$(date +%F)"
```

정상 기대 결과:

- `activity-segments`에 `app_name`, `window_title`, `duration_seconds`, `sample_count`가 저장됩니다.
- 상세 타임라인에는 `activity_segment`가 보입니다.
- 기본 타임라인에는 ActivitySegment가 직접 나열되지 않습니다.

실패 시 의심 원인:

- 기록 상태가 `active`가 아닙니다.
- Mac 앱이 실행 중이 아니거나 ActiveWindowCollector가 시작되지 않았습니다.
- 앱/창 제목 접근 권한이 부족해 `window_title`이 비어 있을 수 있습니다.

## 6. PrivateApp 제외 확인

설정 명령:

```bash
curl -X POST http://127.0.0.1:8765/settings/private-apps \
  -H "Content-Type: application/json" \
  -d '{"app_name":"Discord","match_type":"exact","is_enabled":true}'
curl http://127.0.0.1:8765/settings/private-apps
```

절차:

1. 기록을 시작합니다.
2. Discord 또는 등록한 제외 앱을 활성화합니다.
3. 다시 일반 앱으로 돌아옵니다.

확인:

```bash
curl "http://127.0.0.1:8765/activity-segments?date=$(date +%F)"
curl "http://127.0.0.1:8765/timeline/today?date=$(date +%F)"
```

정상 기대 결과:

- 제외 앱은 새 ActivitySegment로 저장되지 않습니다.
- Mac 앱 UI에는 구체 앱/창 이름 대신 `비공개 앱` 또는 `비공개 앱 사용 중`이 표시됩니다.
- 기본 타임라인과 리포트 입력에 제외 앱의 구체 정보가 나오지 않습니다.

실패 시 의심 원인:

- `match_type`이 실제 앱 이름과 맞지 않습니다.
- PrivateApp 규칙이 `is_enabled=false`입니다.
- 이미 저장된 과거 데이터는 자동 삭제되지 않습니다.

## 7. OCR 수집 확인

사전 확인:

- macOS 시스템 설정에서 MwohamMac 또는 Xcode 실행 앱에 화면 기록 권한을 부여합니다.
- 기록 상태가 `active`여야 합니다.
- PrivateApp 또는 MwohamMac 자기 자신이 활성 상태면 OCR은 중지됩니다.

확인 명령:

```bash
curl "http://127.0.0.1:8765/screen-observations?date=$(date +%F)&limit=20"
```

정상 기대 결과:

- `ocr_text`, `detected_keywords`, `frame_hash`가 저장됩니다.
- 기본 설정에서는 `ai_inference`가 `null`일 수 있습니다.
- OCR 상태는 `OCR 저장됨`, `OCR 텍스트 부족`, `OCR 품질 낮음`, `비공개 앱으로 OCR 중지`, `권한 필요` 중 상황에 맞게 표시됩니다.

실패 시 의심 원인:

- 화면 기록 권한이 없습니다.
- 기록 상태가 `active`가 아닙니다.
- OCR 텍스트가 너무 짧거나 품질 필터에 걸렸습니다.
- 같은 화면이 반복되어 중복 저장이 생략되었습니다.
- PrivateApp 또는 MwohamMac 자기 자신이 활성 상태입니다.

## 8. 기본 타임라인 확인

확인:

```bash
curl "http://127.0.0.1:8765/timeline/today?date=$(date +%F)"
open "http://127.0.0.1:8765/timeline"
open "http://127.0.0.1:8765/timeline?filter=command"
open "http://127.0.0.1:8765/timeline?filter=command_failed"
open "http://127.0.0.1:8765/timeline?date=$(date +%F)&filter=git"
```

정상 기대 결과:

- 웹 기본 타임라인은 최신 항목이 위에 표시됩니다.
- API `/timeline/today` 응답은 report 입력 흐름을 위해 기존 시간순을 유지합니다.
- `filter=all` 또는 알 수 없는 filter 값은 전체 항목을 표시합니다.
- `filter=dev`는 DevEvent 전체를 표시합니다.
- `filter=git`은 자동 Git tracking 이벤트를 확인하는 용도입니다.
- `filter=command`는 터미널 command_result 전체를 표시합니다.
- `filter=command_failed`는 실패한 터미널 명령만 확인하는 용도입니다.
- `filter=meeting`은 회의 전사를 표시합니다.
- `filter=memo`는 수동 메모를 표시합니다.
- `filter=report`는 일일 리포트를 표시합니다.
- `date`와 `filter` query는 함께 동작합니다.
- 기본 타임라인은 작업 흐름 중심으로 간결하게 보입니다.
- ManualMemo는 표시됩니다.
- 일반 WorkEvent는 표시됩니다.
- `source="mac_active_window"` WorkEvent는 표시되지 않습니다.
- ActivitySegment는 직접 나열되지 않습니다.
- ScreenObservation은 raw OCR 전문 대신 `ai_inference` 또는 `화면 텍스트 수집됨`으로 표시됩니다.
- 자기 서비스 화면 OCR은 기본 타임라인에서 제외됩니다.
- 시간은 한국시간 기준으로 표시됩니다.

실패 시 의심 원인:

- 상세 타임라인과 혼동했습니다.
- OCR이 저장되지 않았거나 기본 타임라인 필터에 의해 숨겨졌습니다.
- 자기 서비스 화면만 수집되어 기본 타임라인에 표시할 항목이 없습니다.

## 9. 상세 타임라인 확인

확인:

```bash
curl "http://127.0.0.1:8765/timeline/today/detail?date=$(date +%F)"
open "http://127.0.0.1:8765/timeline/detail"
open "http://127.0.0.1:8765/timeline/detail?filter=memo"
```

정상 기대 결과:

- 제목에 `상세 타임라인`이 표시됩니다.
- 웹 상세 타임라인은 최신 항목이 위에 표시됩니다.
- API `/timeline/today/detail` 응답은 report 입력 흐름을 위해 기존 시간순을 유지합니다.
- 상세 타임라인에서도 `date`와 `filter` query가 함께 동작합니다.
- ActivitySegment가 표시됩니다.
- ScreenObservation은 OCR 발췌 중심으로 표시됩니다.
- Memo, WorkEvent, Meeting, Transcript도 확인할 수 있습니다.

실패 시 의심 원인:

- 웹 상세 화면은 `/timeline/detail`, API 상세 타임라인은 `/timeline/today/detail`입니다.
- ActivitySegment가 없다면 기록 상태가 active가 아니었거나 Mac 앱 collector가 동작하지 않았습니다.

## 10. 회의 전사 확인

사전 확인:

- backend가 실행 중이어야 합니다.
- Mac 앱이 실행 중이어야 합니다.
- macOS 시스템 설정에서 MwohamMac 또는 Xcode 실행 앱에 선택한 전사 source별 권한을 부여합니다.

절차:

1. Mac 앱에서 전사 입력 source를 선택합니다.
   - 마이크
   - 시스템 오디오
   - 회의 전체
2. 회의 전체 Local Whisper를 확인하려면 `whisper-cli`와 GGML model의 저장소 밖
   절대 경로를 입력합니다.
3. Mac 앱에서 `회의 전사 시작`을 누릅니다.
4. 권한 요청이 표시되면 필요한 권한을 허용합니다.
5. 마이크 source에서는 한국어로 짧은 문장과 의미 있는 문장을 말합니다.
6. 시스템 오디오 source에서는 브라우저, ZEP, Meet, Zoom 등에서 한국어 음성을 재생합니다.
7. 회의 전체 source에서는 마이크 발화와 시스템 오디오 재생을 함께 확인합니다.
8. Mac 앱에서 최근 전사 텍스트와 `STT engine` 표시를 확인합니다.
9. `회의 전사 종료`를 누르고 Local Whisper 처리가 완료될 때까지 기다립니다.

확인 명령:

```bash
curl "http://127.0.0.1:8765/meeting-transcripts/today"
curl "http://127.0.0.1:8765/status"
```

정상 기대 결과:

- `/status`에서 회의 중에는 `meeting_mode=true`로 표시됩니다.
- `/meeting-transcripts/today`에 선택한 source에 맞는 transcript가 저장됩니다.
  - `apple_speech_microphone`
  - `apple_speech_system_audio`
  - `apple_speech_full_meeting`
  - `local_whisper_full_meeting`
- Whisper 성공 시 `local_whisper_full_meeting`만 최종 저장됩니다.
- Whisper binary/model 미설정 또는 실행 실패 시 `apple_speech_full_meeting`으로 fallback합니다.
- 원본 오디오는 영구 저장되지 않고, 임시 WAV는 처리 후 삭제됩니다.
- backend로 audio data가 전송되지 않고 transcript text만 저장됩니다.
- 회의 전사 종료 후 앱 상태가 `회의 전사 종료됨` 또는 `전사 저장 후 종료됨` 계열로 표시됩니다.

실패 시 의심 원인:

- 음성 인식 권한 또는 마이크 권한이 없습니다.
- 권한을 허용한 뒤 앱을 재실행하지 않았습니다.
- 너무 짧은 전사 조각이 저장 품질 정책에 의해 제외되었습니다.
- backend가 실행 중이 아니거나 Local API Token 설정이 앱과 맞지 않습니다.
- Whisper binary에 실행 권한이 없거나 model 경로가 잘못되었습니다.
- `/private/tmp/mwoham-meeting-whisper-*`가 남아 있다면 앱이 처리 중 강제 종료됐는지 확인합니다.

## 11. 자동 Dev Tracking 확인

사전 확인:

- backend가 실행 중이어야 합니다.
- Mac 앱이 실행 중이어야 합니다.
- uv와 git이 설치되어 있어야 합니다.
- 앱 설정의 Dev Tracking 추적 repo 경로가 비어 있거나 유효한 Git repo여야 합니다.

절차:

1. PyCharm, Visual Studio Code, Code, Terminal, iTerm, iTerm2, Cursor 중 하나를 활성화합니다.
2. 앱 상태, 메뉴바, 플로팅 위젯에서 Dev Tracking 상태를 확인합니다.
3. Git repo에서 파일을 수정합니다.
4. debounce/interval 이후 DevEvent 저장 여부를 확인합니다.
5. Chrome 같은 비개발 앱으로 이동한 뒤 grace period 후 watcher가 종료되는지 확인합니다.

확인 명령:

```bash
curl "http://127.0.0.1:8765/dev-events/today?date=$(date +%F)"
curl "http://127.0.0.1:8765/timeline/today/detail?date=$(date +%F)"
```

정상 기대 결과:

- 개발 도구 활성화 시 `Dev Tracking: 감시 시작` 또는 `Dev Tracking: 개발 도구 감지됨, 감시 중`이 표시됩니다.
- 변경이 없으면 `Dev Tracking: 변경 없음`이 표시됩니다.
- 변경 직후에는 `Dev Tracking: 변경 감지, 안정화 대기 중`이 표시될 수 있습니다.
- 안정화 후 `Git 변경 감지: ...` 요약이 표시됩니다.
- watcher가 같은 signature를 반복 저장하지 않습니다.
- `*.swp`, `*.swo`, `.DS_Store`, cache, coverage 산출물만 있는 경우 DevEvent가 저장되지 않습니다.
- DevEvent details에는 diff_summary 같은 안전한 메타데이터가 저장되고 raw diff 본문은 저장되지 않습니다.

실패 시 의심 원인:

- 활성 앱이 개발 도구 목록에 없습니다.
- repo path가 존재하지 않거나 Git repo가 아닙니다.
- 앱 실행 환경 PATH에서 uv 또는 git을 찾지 못합니다.
- backend 경로 fallback이 현재 실행 위치와 맞지 않습니다.
- watcher stdout/stderr에 오류가 표시됐는지 확인합니다.

## 12. 리포트 생성 확인

확인 명령:

```bash
curl -X POST http://127.0.0.1:8765/reports/daily \
  -H "Content-Type: application/json" \
  -d "{\"date\":\"$(date +%F)\"}"
curl "http://127.0.0.1:8765/reports/today?date=$(date +%F)"
```

웹 확인:

- `http://127.0.0.1:8765/reports`에서 mode별 생성 버튼을 누릅니다.
- 생성된 리포트 상세 화면을 엽니다.
- `http://127.0.0.1:8765/reports`의 오늘 리포트 영역에 `간단 리포트 생성`과
  `상세 리포트 생성` 버튼이 각각 표시되는지 확인합니다.
- `간단 리포트 생성`은 simple mode report를 만들고, `상세 리포트 생성`은 detailed
  mode report를 만들어야 합니다.

정상 기대 결과:

- Gemini 호출에 성공하면 `created_by="ai"`입니다.
- Gemini API key가 없거나 quota 초과면 `created_by="system"` fallback 리포트가 생성됩니다.
- 같은 `date + mode + project_id`로 `/reports/daily`를 여러 번 실행해도 새 row가
  계속 늘지 않고 기존 리포트가 갱신됩니다.
- `/reports/today`는 list schema를 유지하면서 오늘 날짜 최신 리포트 1개를 맨 위
  `items[0]`에 보여줍니다.
- `/reports/today?mode=detailed`는 오늘 최신 상세 리포트 1개를 반환합니다.
- `/reports/today?mode=simple`은 오늘 최신 간단 리포트 1개를 반환합니다.
- `POST /reports/daily?mode=simple`처럼 query mode를 넘겨도 해당 mode로 생성됩니다.
  body와 query에 mode가 모두 있으면 query mode를 우선합니다.
- fallback 리포트는 raw timeline 전체 덤프가 아니라 요약, 주요 메모, 주요 화면 관찰, 주요 작업 환경 중심으로 짧게 생성됩니다.
- daily report는 `detailed`와 `simple` 두 mode를 지원합니다.
- `detailed`는 `오늘 한 일 요약`, `시간대별 작업 흐름`, `주요 트러블슈팅`,
  `회의/메모에서 나온 결정사항`, `다음 작업 후보` 섹션을 유지합니다.
- `simple`은 `오늘 한 일 요약`, `완료한 작업`, `다음 작업`, `테스트/검증 결과`
  섹션으로 짧게 생성됩니다.
- `simple` fallback은 화면 OCR raw text를 완료한 작업에 직접 넣지 않고, memo,
  dev_event, command/test result, meeting transcript 같은 high-confidence 근거만
  우선 사용합니다. 근거가 부족하면 `확인된 핵심 작업 없음`으로 표시합니다.
- `simple` fallback은 high-confidence 근거도 원문 그대로 출력하지 않고 짧은 사용자
  문장으로 요약합니다. meeting transcript의 `[00:00 microphone]` prefix, dev_event의
  `changed_files=`, `exit_code=`, `duration_ms=`, `cwd=` 같은 raw metadata, `curl`
  명령 문자열은 본문에 직접 나오지 않아야 합니다.
- 같은 날짜에 `detailed`와 `simple`을 각각 생성해도 서로 덮어쓰지 않고 다른
  mode의 report로 유지됩니다.
- `CURRENT_WORK_FOCUS`가 있으면 오늘 한 일 요약과 시간대별 작업 흐름이 최신 작업 주제를 우선 반영합니다.
- 자동 watcher 기반 `git_snapshot`은 report input에서 20분 버킷과 branch 기준으로 압축됩니다.
- report 생성 시점의 `CURRENT_GIT_CHANGE_HINTS`와 `CURRENT_GIT_DIFF_CONTEXT`가 있으면 구체 작업 의도 파악에 우선 사용됩니다.
- terminal `command_result`는 `PRIORITY_COMMAND_FLOWS`에서 `failed_to_success`, `failed_only`, `development_validation`, `inspection`, `cleanup` 흐름으로 구분됩니다.
- failed command는 실제 장애로 과장되지 않고 주변 context와 함께 보수적으로 해석됩니다.
- inspection/setup command는 보조 근거로만 쓰이며, cleanup command는 간결하게 요약됩니다.
- 회의 전사는 결정사항, 논의사항, 후속작업 후보로 나뉘어 반영됩니다.
- 이미 완료/검증/문서화된 기능이 다음 작업 후보로 반복 제안되지 않습니다.
- raw git diff는 DB, DevEvent, log, Report.content에 그대로 저장되지 않습니다.
- stdout/stderr 전체, shell history, 키 입력 내용은 저장되지 않습니다.

후속 개선 후보:

- report input pruning
- event relevance scoring
- QA/noise event tagging
- meeting transcript report quality
- daily review dashboard refinement

실패 시 의심 원인:

- `GEMINI_API_KEY`가 없습니다.
- Gemini quota가 초과되었습니다.
- Gemini 모델명이 잘못되었습니다.
- 타임라인에 리포트에 넣을 데이터가 거의 없습니다.

## 13. PDF 다운로드 확인

1. 리포트를 생성합니다.
2. 리포트 ID를 확인합니다.

명령:

```bash
REPORT_ID=1
curl -X POST "http://127.0.0.1:8765/reports/${REPORT_ID}/export" \
  -H "Content-Type: application/json" \
  -d '{"export_format":"pdf"}'
curl -OJ "http://127.0.0.1:8765/reports/${REPORT_ID}/download?format=pdf"
```

정상 기대 결과:

- PDF 파일이 다운로드됩니다.
- export 파일은 `backend/exports/reports` 또는 `REPORT_EXPORT_DIR`에 저장됩니다.
- 다운로드 파일이 PDF viewer에서 열립니다.

실패 시 의심 원인:

- 리포트 ID가 존재하지 않습니다.
- PDF 생성 의존성 또는 시스템 폰트 문제가 있습니다.
- export 디렉터리 쓰기 권한이 없습니다.

## 14. 원본 이미지/오디오/raw diff 미저장 확인

확인 명령:

```bash
find . \
  -path './.git' -prune -o \
  -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.tiff' \) \
  -print
git status --short
```

정상 기대 결과:

- OCR 수집 때문에 새 스크린샷 이미지 파일이 생성되지 않습니다.
- backend에는 OCR 텍스트만 저장됩니다.
- `git status --short`에 캡처 이미지 파일이 나타나지 않습니다.
- 회의 전사 때문에 원본 오디오 파일이나 raw audio buffer 파일이 생성되지 않습니다.
- DevEvent에는 raw git diff 본문이나 파일 내용이 저장되지 않습니다.

실패 시 의심 원인:

- 개발 중 수동으로 만든 캡처 파일이 남아 있습니다.
- 외부 캡처 도구가 파일을 저장했습니다.
- 앱 코드가 아닌 별도 디버깅 스크립트가 이미지를 저장했습니다.

## 15. Gemini quota 초과 fallback 확인

확인 명령:

```bash
cd backend
uv run python -c "from app.ai.gemini_client import GeminiClient; from app.core.config import settings; c=GeminiClient(api_key=settings.gemini_api_key, model=settings.gemini_model, max_output_tokens=128); r=c.generate_text_result('한국어 한 문장으로 답하세요.'); print({'has_text': bool(r.text), 'error_reason': r.error_reason, 'status_code': r.status_code, 'finish_reason': r.finish_reason})"
```

정상 기대 결과:

- quota가 충분하면 `has_text=True`입니다.
- quota 초과 시 `error_reason='quota_exceeded'`, `status_code=429`가 확인됩니다.
- `/reports/daily`는 실패 reason을 로그에 남기고 `created_by="system"` fallback 리포트를 생성합니다.
- API key 값은 로그와 응답에 출력되지 않습니다.

실패 시 의심 원인:

- `.env`가 로드되지 않았습니다.
- API key가 잘못되었습니다.
- `GEMINI_MODEL`이 계정에서 사용할 수 없는 모델입니다.
- 네트워크 연결 또는 Google API 접근이 실패했습니다.

## 16. Local Whisper 회의 전체 오디오 품질 확인

사전 준비:

- 앱의 `전사 입력`을 `회의 전체`로 선택합니다.
- 저장소 밖 `whisper-cli`와 GGML model 절대 경로를 입력합니다.
- 기본 검증에서는 `QA/debug용 source별 WAV 보관`을 끕니다.

절차:

1. 회의를 시작하고 microphone으로 한국어 문장을 말합니다.
2. 이어폰 없이 ZEP/Chrome에서 다른 한국어 음성을 재생합니다.
3. 회의를 종료하고 `STT engine`과 `Whisper metadata`를 확인합니다.
4. `/meeting-transcripts/today`에서 transcript source를 확인합니다.
5. system audio 없음, microphone 없음, source 하나의 저정보 결과를 각각
   확인합니다.
6. 무음/잡음 구간과 같은 문장 또는 음절이 3회 이상 반복되는 테스트 음성을
   포함해 chunk reject 동작을 확인합니다.
7. 모든 chunk가 reject되는 경우와 binary/model 오류를 유도해 Apple Speech
   fallback을 확인합니다.

정상 기대 결과:

- Whisper 성공 시 `source=local_whisper_full_meeting`으로 저장됩니다.
- microphone/system audio가 각각 독립 WAV와 Whisper 입력으로 표시됩니다.
- 두 source가 성공하면 최종 transcript가 source별 전체 묶음이 아니라
  `[00:12 microphone]`, `[00:15 system_audio]` 같은 시간순 segment 목록으로
  저장됩니다.
- source별 WAV duration이 capture duration과 크게 어긋나지 않습니다.
- source별 15초 chunk 수, accepted/rejected 수, source별 accepted count,
  temporal merge 적용 여부, reject reason 요약, 처리 시간, transcript 길이가
  UI에 표시됩니다.
- `"아쩡하쩡하쩡..."`, 같은 문장의 과도한 반복, 점/공백 위주 chunk는 rejected되고
  정상 발화 chunk만 최종 transcript에 남습니다.
- 한 source가 없거나 실패해도 다른 source transcript는
  `local_whisper_full_meeting`으로 저장됩니다.
- 한 source의 모든 chunk가 reject되면 해당 source만 최종 transcript에서
  제외됩니다.
- 두 source의 모든 chunk가 reject되거나 모두 실패하면 Apple Speech 결과와
  `fallback=yes`가 표시됩니다.
- 기본 실행 후 `/private/tmp/mwoham-meeting-whisper-*`가 남지 않습니다.

debug 오디오 확인:

- toggle을 명시적으로 켠 회의만
  `~/Library/Application Support/Mwoham/debug_audio/`에 source별 최종 WAV와
  chunk WAV가 남습니다.
- toggle을 끈 다음 회의부터 새 debug WAV가 생성되지 않아야 합니다.
- repo 내부와 `git status`에는 model/WAV/임시 output이 나타나지 않아야 합니다.

## 9. macOS 타임라인 UX 확인

확인:

1. macOS 앱을 실행하고 왼쪽 내비게이션에서 `타임라인`을 엽니다.
2. backend가 연결된 상태에서 `타임라인 새로고침`을 누릅니다.
3. 오늘 기록이 오전/오후/저녁/밤 시간대 카드로 묶여 보이는지 확인합니다.
4. 각 시간대 카드에 이벤트 개수, 중요 이벤트 개수, 리포트 후보 표시가
   자연스럽게 나타나는지 확인합니다.
5. 앱 활동, 메모, 회의, 개발 이벤트가 각 카드에서 타입 badge로 구분되는지
   확인합니다.
6. 필터를 `전체`, `앱 활동`, `메모`, `회의`, `개발 이벤트`, `중요 이벤트`로
   바꿔 결과가 즉시 바뀌는지 확인합니다.
7. 짧은 앱 전환이나 5분 안에 반복된 동일 앱/창 이벤트가 `접힌 이벤트` 아래로
   접히는지 확인합니다.
8. backend를 끄거나 `/health` 실패 상태를 만든 뒤 타임라인 화면에 오류 banner가
   표시되는지 확인합니다.
9. 기록이 없는 날짜 또는 빈 DB 상태에서 `오늘 기록 없음` 빈 상태가 표시되는지
   확인합니다.
10. 필터 결과가 없는 경우 `필터 결과 없음` 빈 상태가 표시되는지 확인합니다.

정상 기대 결과:

- 타임라인 조회는 기존 `/timeline/today/detail` API만 사용하며 backend schema나
  report 생성 로직을 바꾸지 않습니다.
- 앱 활동, 수동 메모, 회의 전사, Dev Tracking 이벤트가 한 화면에서 구분됩니다.
- 노이즈 이벤트는 삭제하지 않고 UI 단계에서 접어 볼 수 있습니다.
- 상세 정보는 카드 안의 `상세 보기` 또는 `접힌 이벤트`에서 확인할 수 있습니다.
- 메뉴바, 플로팅 위젯, 기록 시작/중지, backend lifecycle 동작은 기존과 같습니다.

검증 명령:

```bash
./scripts/test_macos_timeline_presentation.sh
./scripts/build_macos_app.sh --open
git diff --check
```

## 10. macOS 리포트 편집 UX 확인

확인:

1. macOS 앱을 실행하고 왼쪽 내비게이션에서 `리포트`를 엽니다.
2. backend가 연결된 상태에서 `리포트 새로고침`을 누릅니다.
3. 오늘/최근이 별도 섹션으로 나뉘지 않고 하나의 리포트 목록에 표시되는지
   확인합니다.
4. 목록이 날짜별로 그룹핑되고 오늘 날짜 그룹은 `오늘 · YYYY-MM-DD`로 표시되는지
   확인합니다.
5. 각 리포트 카드에 mode badge, 제목, 미리보기, 생성/수정 시각, 최신 표시가
   보이는지 확인합니다.
6. `간단 생성`, `상세 생성` 버튼으로 각각 리포트를 생성하고, 생성 후 상세 sheet가
   열리는지 확인합니다.
7. 리포트 카드를 클릭하면 하단 고정 패널이 아니라 modal sheet로 상세가 열리는지
   확인합니다.
8. 상세 sheet에서 Markdown 원문, mode badge, 생성자 badge, 생성/수정 시각이
   표시되는지 확인합니다.
9. sheet 안에서 `편집`을 눌러 Markdown을 수정하고 `저장`하면 목록 카드와 상세
   내용이 갱신되는지 확인합니다.
10. 편집 중 `취소`를 누르면 마지막 저장본으로 복원되는지 확인합니다.
11. 저장하지 않은 변경사항이 있을 때 warning banner가 표시되는지 확인합니다.
12. `전체 복사`로 전체 Markdown이 클립보드에 들어가는지 확인합니다.
13. `PDF 내보내기`를 누르면 저장 위치를 선택할 수 있고 PDF 파일이 생성되는지
   확인합니다.
14. `섹션별 보기`와 `섹션 복사` UI가 남아 있지 않은지 확인합니다.
15. 리포트가 없는 상태에서는 EmptyStateView가 표시되는지 확인합니다.
16. backend 연결 실패, PATCH 실패, PDF export 실패 상태에서 ErrorBanner가
   표시되는지 확인합니다.

정상 기대 결과:

- 리포트 조회/생성/수정은 기존 `/reports` API만 사용하며 backend report 생성
  로직은 변경하지 않습니다.
- detailed/simple mode가 UI에서 명확히 구분됩니다.
- Markdown 원문은 그대로 보존되고, 섹션별 보기 없이 전체 보기/복사/편집 중심으로
  동작합니다.
- PDF 내보내기는 backend API를 추가하지 않고 macOS 앱 로컬 기능으로 처리합니다.
- 저장 실패 시 기존 저장본은 유지되고 편집 중인 draft는 화면에 남습니다.
- 오늘/타임라인/회의 전사/설정, 메뉴바, 플로팅 위젯, backend lifecycle 동작은
  기존과 같습니다.

검증 명령:

```bash
./scripts/test_macos_report_presentation.sh
./scripts/build_macos_app.sh --open
git diff --check
```

## 11. 웹 리포트 편집 UX 확인

확인:

1. backend를 실행하고 브라우저에서 `/reports`에 진입합니다.
2. 기존 리포트 목록이 날짜별 그룹으로 표시되는지 확인합니다.
3. 오늘 날짜 그룹은 `오늘 · YYYY-MM-DD`로 표시되는지 확인합니다.
4. 각 리포트 카드에 detailed/simple badge, 제목, preview, 생성/수정 시각, 최신
   표시가 보이는지 확인합니다.
5. 리포트 카드를 클릭하면 현재 페이지 안에서 상세 modal이 열리는지 확인합니다.
6. 상세 modal에서 Markdown 원문, mode, 생성/수정 시각이 표시되는지 확인합니다.
7. `편집`을 누르면 textarea 편집 모드로 전환되는지 확인합니다.
8. Markdown을 수정하고 `저장`하면 modal 내용과 목록 카드 preview/수정 시각이
   갱신되는지 확인합니다.
9. 편집 중 `취소`를 누르면 마지막 저장본으로 복원되는지 확인합니다.
10. 저장하지 않은 변경사항이 있을 때 warning 문구가 표시되는지 확인합니다.
11. `전체 복사`가 클립보드에 Markdown 원문을 복사하는지 확인합니다.
12. PATCH 저장 실패 또는 복사 실패 시 modal 안에 오류 메시지가 표시되는지
   확인합니다.
13. 리포트가 없는 상태에서는 빈 상태 문구가 표시되는지 확인합니다.
14. 웹 리포트 modal에는 `PDF 내보내기` 버튼이 없는지 확인합니다.

정상 기대 결과:

- 웹 리포트 편집은 기존 `PATCH /reports/{id}` API를 사용하며 새 backend API를
  추가하지 않습니다.
- backend report 생성 로직, DB/schema, macOS 앱 파일은 변경하지 않습니다.
- 저장 성공 시 화면 state가 갱신되고, 저장 실패 시 기존 저장본은 유지됩니다.
- PDF 내보내기는 macOS 앱 로컬 기능으로만 유지합니다.

검증 명령:

```bash
cd backend
uv run pytest -q
uv run python scripts/run_dev_checks.py --no-record
cd ..
git diff --check
```

## 12. Activity Event 정제 QA

확인:

1. macOS 앱에서 기록을 시작하고 여러 앱/창을 전환합니다.
2. 10~30초 이하로 짧게 머문 앱 전환이 타임라인에서 기본적으로 접히는지 확인합니다.
3. 같은 앱과 같은 창 제목이 연속으로 반복되면 하나의 작업 구간으로 압축되어
   보이는지 확인합니다.
4. 빈 제목, `unknown`, `Untitled`, 앱 이름과 동일한 창 제목이 표시용 제목에서
   과하게 반복되지 않는지 확인합니다.
5. 긴 작업 구간은 `high_signal`로 취급되어 중요 이벤트 필터에서 계속 보이는지
   확인합니다.
6. 짧은 앱 전환이나 의미 약한 창 제목은 `low_signal` 또는 기본 접힘 상태로
   표시되는지 확인합니다.
7. 수동 메모, 회의 전사, Dev Tracking 이벤트는 Activity Event 정제 때문에
   숨겨지지 않는지 확인합니다.
8. `/activity-segments?date=YYYY-MM-DD` 원본 목록에는 원본 segment가 삭제되지 않고
   남아 있는지 확인합니다.
9. `/timeline/today/detail?date=YYYY-MM-DD` 응답의 activity item에 `display_title`,
   `signal_level`, `hidden_by_default`, `noise_reason`, `event_count`가 내려오는지
   확인합니다.
10. 리포트 조회/편집, backend lifecycle, 메뉴바, 플로팅 위젯 동작이 기존과 같은지
    확인합니다.

정상 기대 결과:

- Activity Event 원본 DB row는 삭제하지 않습니다.
- 정제는 service/presentation layer에서 수행되고 timeline detail 응답에 표시용
  metadata로 반영됩니다.
- 타임라인 UI는 backend 정제 힌트를 우선 사용하고, 오래된 응답에는 기존 fallback
  접힘 정책을 유지합니다.
- report 생성 로직, DB/schema, STT, recording, Dev Tracking 정책은 변경하지 않습니다.

검증 명령:

```bash
./scripts/test_macos_timeline_presentation.sh
./scripts/build_macos_app.sh --open
git diff --check

cd backend
uv run python scripts/run_dev_checks.py --no-record
uv run pytest -q
```

## 13. TimelineBuilder 리포트 입력 품질 QA

확인:

1. Dev Tracking이 켜진 상태에서 리포트를 생성합니다.
2. “Git 변경 사항을 확인했습니다”, “브랜치에서 Git 변경 감지” 같은 문장이 오늘 한 일
   요약이나 시간대별 작업 흐름에 과하게 나오지 않는지 확인합니다.
3. `changed_files=`, `duration_ms=`, `cwd=`, `exit_code=` 같은 raw metadata가 리포트
   본문에 노출되지 않는지 확인합니다.
4. 파일 경로가 길게 나열되지 않고, `타임라인 작업 근거 품질 개선`, `리포트 입력 품질
   개선`처럼 작업 단위로 요약되는지 확인합니다.
5. `pytest`, `run_dev_checks.py`, `ruff`, `alembic`, `xcodebuild`, `git diff --check`는
   작업 흐름이 아니라 테스트/검증 결과 쪽에 반영되는지 확인합니다.
6. manual memo가 있으면 자동 Git evidence보다 우선적으로 작업 요약 근거에 반영되는지
   확인합니다.
7. 11차 Activity Event 정제 결과 중 `hidden_by_default` 또는 `low_signal` activity가
   핵심 작업 요약으로 승격되지 않는지 확인합니다.
8. `high_signal` 또는 `medium_signal` activity는 작업 환경 근거로만 보조 반영되는지
   확인합니다.
9. Gemini 호출 실패 fallback 리포트에서도 Git 파일 나열 대신 작업 후보와 검증 결과가
   분리되는지 확인합니다.
10. 타임라인 화면, 리포트 편집 화면, 웹 reports 화면이 기존처럼 동작하는지 확인합니다.

정상 기대 결과:

- TimelineBuilder/report prompt 입력은 raw event 나열보다 `REPORT_EVIDENCE_BLOCKS`와
  검증 evidence 중심으로 압축됩니다.
- Git snapshot, changed files, branch switch는 작업 결과의 근거로만 사용됩니다.
- 테스트/빌드/check 결과는 검증 결과로 분리됩니다.
- DB/schema, backend API, report 생성 API 계약, macOS UI 구조는 변경하지 않습니다.

검증 명령:

```bash
cd backend
uv run pytest -q
uv run python scripts/run_dev_checks.py --no-record

cd ..
./scripts/test_macos_timeline_presentation.sh
./scripts/build_macos_app.sh --open
git diff --check
```

## 14. TimelineBuilder/report evidence 보완 QA

확인:

1. detailed 리포트를 생성하고 시간대별 작업 흐름에 `git checkout`, `git branch`,
   `git status`, `git diff`, `git log` 계열 명령이 직접 나오지 않는지 확인합니다.
2. “브랜치로 전환했습니다”, “checkout 명령이 성공적으로 실행되었습니다”,
   “Git 변경 사항을 확인했습니다” 같은 문장이 본문에 남지 않는지 확인합니다.
3. 브랜치명은 작업명 추론에만 쓰이고 본문에는 과하게 노출되지 않는지 확인합니다.
4. 같은 작업이 점 이벤트와 구간 이벤트로 중복 표시되지 않고, 작업 구간 중심으로
   정리되는지 확인합니다.
5. 파일 경로가 길게 나열되지 않고 `리포트 입력 품질 개선`, `macOS 타임라인 표시 정책`,
   `fallback report 구성` 같은 도메인 단위로 설명되는지 확인합니다.
6. `changed_files=`, `cwd=`, `duration_ms=`, `exit_code=` 같은 raw metadata가 simple/detailed
   리포트 본문에 노출되지 않는지 확인합니다.
7. `pytest`, `run_dev_checks.py`, `build_macos_app.sh`, `test_macos_timeline_presentation.sh`,
   `test_macos_report_presentation.sh`, `git diff --check`는 테스트/검증 결과 섹션으로
   분리되는지 확인합니다.
8. 다음 작업 후보가 완료한 파일명/테스트명 대신 로드맵 중심으로 제안되는지 확인합니다.
   - 13차 Launch at Login
   - 14차 메뉴바/플로팅 위젯 리팩토링
   - 15차 Release 패키징
9. simple 리포트는 짧은 업무 보고 형태로 유지되는지 확인합니다.
10. detailed 리포트는 변경 이유, 변경 전 문제, 변경 후 동작, 관련 영역, 검증 결과,
    영향 없는 범위, 다음 작업 연결을 충분히 설명하는지 확인합니다.
11. Gemini 호출 실패 fallback에서도 동일한 노출 제한과 검증 분리 정책이 적용되는지
    확인합니다.

정상 기대 결과:

- 리포트는 raw dev log가 아니라 실제 작업 단위 중심으로 작성됩니다.
- Git checkout/status/diff/log/branch 계열은 inspection 근거로만 사용됩니다.
- validation command는 작업 흐름이 아니라 테스트/검증 결과로 분리됩니다.
- detailed 리포트는 상세하지만 raw log가 길게 나열되지 않습니다.
- simple 리포트는 짧고 빠르게 읽히는 요약을 유지합니다.

검증 명령:

```bash
cd backend
uv run pytest -q
uv run python scripts/run_dev_checks.py --no-record

cd ..
./scripts/test_macos_timeline_presentation.sh
./scripts/build_macos_app.sh --open
git diff --check
```

## 개발용 검증 명령

백엔드 전체 검증:

```bash
cd backend
uv run ruff check .
uv run pytest
uv run alembic check
cd ..
git diff --check
```

Mac 앱 빌드 검증:

```bash
xcodebuild \
  -project mac-client/MwohamMac/MwohamMac.xcodeproj \
  -scheme MwohamMac \
  -destination platform=macOS \
  -derivedDataPath /private/tmp/MwohamMacDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

이 명령은 CI/컴파일 확인용 unsigned build입니다. 접근성, 화면 기록, 마이크 등
TCC 권한 QA에는 `./scripts/build_macos_app.sh --open`으로 생성한 stable signed
앱을 사용합니다.

자주 보는 API:

```bash
curl http://127.0.0.1:8765/status
curl "http://127.0.0.1:8765/timeline/today?date=$(date +%F)"
curl "http://127.0.0.1:8765/timeline/today/detail?date=$(date +%F)"
curl "http://127.0.0.1:8765/screen-observations?date=$(date +%F)&limit=20"
curl "http://127.0.0.1:8765/activity-segments?date=$(date +%F)"
curl "http://127.0.0.1:8765/reports/today?date=$(date +%F)"
```
