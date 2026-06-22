# QA Checklist

이 문서는 Mwoham v0.1.x 내부 QA/포트폴리오 시연용 DMG와 로컬 개발 빌드의 기능 검증 체크리스트입니다.

## QA 기준

- 앱: `MwohamMac.app`
- Bundle ID: `com.ing2720.MwohamMac`
- backend: `http://127.0.0.1:8765`
- health: `GET /health`
- 내부 QA DMG: `dist/Mwoham-0.1.1.dmg` 또는 최신 `dist/Mwoham-*.dmg`
- 개발/권한 QA stable path: `~/Applications/MwohamMac.app`
- DMG 설치 path: `/Applications/MwohamMac.app`
- component install path: `~/Library/Application Support/Mwoham`
- 공개 배포용 Developer ID signing/notarization은 현재 범위 밖
- Gatekeeper 경고는 발생 가능

## 자동 검증

macOS focused checks:

```bash
./scripts/test_macos_component_installer.sh
./scripts/test_macos_stt_runtime_readiness.sh
./scripts/test_macos_ai_provider_settings.sh
./scripts/test_macos_report_presentation.sh
./scripts/test_macos_timeline_presentation.sh
./scripts/test_macos_floating_widget_settings.sh
./scripts/test_macos_floating_widget_responsive.sh
./scripts/test_macos_menu_bar_floating_presentation.sh
./scripts/test_macos_launch_at_login.sh
./scripts/test_macos_permission_onboarding.sh
```

backend:

```bash
cd backend
uv run python scripts/run_dev_checks.py --no-record
uv run pytest -q
```

basic checks:

```bash
git diff --check
curl http://127.0.0.1:8765/health
curl http://127.0.0.1:8765/status
```

## 설치 / 실행

- [ ] 최신 `dist/Mwoham-*.dmg`를 mount한다.
- [ ] DMG 안에 `MwohamMac.app`이 있다.
- [ ] DMG 안에 `Applications` symlink가 있다.
- [ ] DMG 안에 `README_INSTALL.md`가 있다.
- [ ] 앱을 Applications로 복사한다.
- [ ] DMG 내부 앱을 바로 실행하지 않는다.
- [ ] 복사된 앱을 실행한다.
- [ ] Gatekeeper 경고가 있으면 Finder 우클릭 > 열기 또는 시스템 설정 > 개인정보 보호 및 보안 > Open Anyway로 허용한다.
- [ ] 앱이 실행되고 메인 창이 표시된다.
- [ ] 메뉴바 항목이 표시된다.

## 권한

- [ ] 첫 실행 권한 온보딩이 표시된다.
- [ ] 마이크 권한 요청/상태가 표시된다.
- [ ] 음성 인식 권한 요청/상태가 표시된다.
- [ ] 화면 기록 권한 요청/상태가 표시된다.
- [ ] 접근성 권한 요청/상태가 표시된다.
- [ ] 설정 화면의 권한 카드에서 상태를 다시 확인할 수 있다.
- [ ] 권한 허용 후 상태 새로고침이 가능하다.
- [ ] 화면 기록/접근성 허용 후 앱 재시작 안내가 QA 문서와 일치한다.

권한 초기화가 필요할 때:

```bash
tccutil reset All com.ing2720.MwohamMac
```

## Backend

- [ ] 앱 설정에서 backend 상태가 `연결됨`으로 표시된다.
- [ ] `~/Library/Application Support/Mwoham/backend`가 있으면 우선 사용한다.
- [ ] `component_manifest.json`에 backend status/path가 기록된다.
- [ ] `curl http://127.0.0.1:8765/health`가 정상 응답한다.
- [ ] 앱이 시작한 backend만 앱에서 중지/재시작할 수 있다.
- [ ] 외부 backend가 이미 실행 중이면 앱이 임의로 종료하지 않는다.
- [ ] backend directory 자동 탐색 설명이 설정 화면과 문서에 맞다.
- [ ] backend path override를 설정하고 되돌릴 수 있다.
- [ ] 포트 충돌 시 상태/오류 메시지가 표시된다.

포트 확인:

```bash
lsof -ti :8765
```

## Recording

- [ ] 기록 시작이 가능하다.
- [ ] 기록 일시정지가 가능하다.
- [ ] 기록 재개가 가능하다.
- [ ] 기록 종료가 가능하다.
- [ ] 기록 시간이 갱신된다.
- [ ] backend 연결 실패 시 기록 액션이 안전하게 실패한다.
- [ ] PrivateApp 활성 시 수집/표시 정책이 적용된다.

## Activity / OCR

- [ ] 활성 앱 이름이 표시된다.
- [ ] 접근성 권한이 있으면 창 제목이 표시된다.
- [ ] OCR collector 상태가 표시된다.
- [ ] 화면 기록 권한이 없으면 권한 필요 상태가 표시된다.
- [ ] OCR 결과는 backend에 텍스트와 중복 방지용 정보로 저장된다.
- [ ] 원본 화면 이미지는 파일로 저장되지 않는다.
- [ ] Mwoham 자기 자신 관찰 noise가 필터링된다.

## Dev Tracking

- [ ] 개발 도구 활성화 시 watcher가 자동 시작된다.
- [ ] 비개발 앱 이동 후 grace period 뒤 watcher가 종료된다.
- [ ] 개발 도구 복귀 시 종료 예약이 취소된다.
- [ ] 중복 watcher가 실행되지 않는다.
- [ ] repo path가 비어 있으면 fallback이 적용된다.
- [ ] 잘못된 repo path는 앱 종료 없이 오류 상태로 표시된다.
- [ ] watcher stdout/stderr 요약이 앱 상태에 반영된다.
- [ ] raw git diff와 파일 내용은 저장되지 않는다.

대상 개발 도구:

- PyCharm
- Visual Studio Code
- Code
- Terminal
- iTerm
- iTerm2
- Cursor

## Command Tracking

- [ ] `install_command_tracking_hook.py`가 zsh hook을 설치한다.
- [ ] `mwoham_command_tracking_status`가 상태를 표시한다.
- [ ] `mwoham_command_tracking_disable`로 현재 터미널에서 비활성화할 수 있다.
- [ ] 명령 성공/실패가 DevEvent로 저장된다.
- [ ] stdout/stderr 전체, shell history, 키 입력 내용은 저장되지 않는다.
- [ ] 민감정보가 마스킹된다.

## Timeline

- [ ] `/timeline`이 표시된다.
- [ ] `/timeline/detail`이 표시된다.
- [ ] 최신 항목이 웹에서 확인하기 쉬운 순서로 표시된다.
- [ ] API/report input의 시간순 정책이 유지된다.
- [ ] `filter=all`이 동작한다.
- [ ] `filter=dev`가 동작한다.
- [ ] `filter=git`이 동작한다.
- [ ] `filter=command`가 동작한다.
- [ ] `filter=command_failed`가 동작한다.
- [ ] `filter=meeting`이 동작한다.
- [ ] `filter=memo`가 동작한다.
- [ ] `filter=report`가 동작한다.
- [ ] 알 수 없는 filter는 `all`로 fallback된다.

## Report

- [ ] `/reports`가 표시된다.
- [ ] 오늘 리포트를 생성할 수 있다.
- [ ] key가 없으면 fallback report가 생성된다.
- [ ] 유효한 Gemini/OpenAI key가 있으면 AI report가 생성된다.
- [ ] provider 실패/quota/timeout 시 fallback report가 생성된다.
- [ ] report detail이 표시된다.
- [ ] Markdown export가 가능하다.
- [ ] PDF export가 가능하다.
- [ ] 같은 날짜/모드/project 반복 생성 정책이 의도대로 동작한다.
- [ ] raw git diff가 `Report.content`에 그대로 저장되지 않는다.

## AI Provider

- [ ] Settings에서 Gemini/OpenAI provider를 선택할 수 있다.
- [ ] API Key를 저장할 수 있다.
- [ ] API Key는 macOS Keychain에 저장된다.
- [ ] 저장 후 key 전체 값은 다시 표시되지 않는다.
- [ ] 모델 목록을 불러오거나 연결 테스트할 수 있다.
- [ ] key 삭제가 현재 provider에만 적용된다.
- [ ] 앱이 시작한 backend는 재시작 적용으로 새 provider 환경을 받을 수 있다.
- [ ] 외부 backend는 사용자가 직접 재시작해야 한다는 안내가 맞다.

## STT

- [ ] Settings의 Local Whisper 상태 카드가 표시된다.
- [ ] Application Support `whisper-cli` source가 우선 표시된다.
- [ ] Application Support `ggml-large-v3-turbo` model source가 우선 표시된다.
- [ ] 필요한 dylib가 앱 번들 설치 원본 또는 Application Support runtime에 있다.
- [ ] `component_manifest.json`에 STT CLI/model status/path가 기록된다.
- [ ] `whisper-cli` 실행 권한이 있다.
- [ ] 모델이 없으면 앱 전체가 종료되지 않고 모델 미설치 상태가 표시된다.
- [ ] 마이크 전사가 동작한다.
- [ ] 시스템 오디오 전사가 동작한다.
- [ ] 회의 전체 전사가 동작한다.
- [ ] Apple Speech fallback 상태가 표시된다.
- [ ] Local Whisper 실패 시 앱이 안전하게 안내한다.
- [ ] 원본 오디오는 영구 저장되지 않는다.
- [ ] backend에는 transcript text만 저장된다.

resource check:

```bash
APP="/Applications/MwohamMac.app"
./scripts/check_release_stt_resources.sh "$APP"
```

## Menu Bar

- [ ] 메뉴바 extra가 표시된다.
- [ ] backend 상태가 표시된다.
- [ ] recording 상태/시간이 표시된다.
- [ ] Dev Tracking 상태가 표시된다.
- [ ] 회의 모드 액션이 동작한다.
- [ ] 메인 창 열기가 동작한다.
- [ ] 대시보드 열기가 동작한다.
- [ ] 앱 종료가 동작한다.

## Floating Widget

- [ ] 메뉴바에서 floating widget을 열 수 있다.
- [ ] floating widget을 닫을 수 있다.
- [ ] compact/regular/spacious layout이 깨지지 않는다.
- [ ] opacity 설정이 적용된다.
- [ ] color preset이 적용된다.
- [ ] 표시 항목 ON/OFF가 적용된다.
- [ ] 빠른 액션 ON/OFF가 적용된다.
- [ ] 기본값 초기화가 동작한다.
- [ ] 좁은 크기에서도 텍스트가 심하게 겹치지 않는다.

## Launch at Login

- [ ] Settings의 Launch at Login toggle이 표시된다.
- [ ] toggle on/off가 동작한다.
- [ ] macOS 로그인 항목 상태가 갱신된다.
- [ ] 상태 새로고침이 동작한다.
- [ ] 앱 경로가 AppTranslocation이면 진단이 표시된다.
- [ ] 로그인 시 앱 실행만 담당하고 recording은 자동 시작하지 않는다.

## DMG Packaging

- [ ] `./scripts/package_macos_dmg.sh --version 0.1.1 --internal-qa`가 성공한다.
- [ ] 최신 `dist/Mwoham-*.dmg`가 생성된다.
- [ ] `hdiutil verify`가 성공한다.
- [ ] DMG mount/detach가 가능하다.
- [ ] Applications symlink가 있다.
- [ ] `README_INSTALL.md`가 있다.
- [ ] STT model/runtime/dylib가 app bundle에 있다.
- [ ] 앱 실행 후 Application Support component manifest가 생성된다.
- [ ] backend/STT runtime이 앱 번들 내부를 쓰기 위치로 사용하지 않는다.
- [ ] Homebrew absolute dylib dependency가 남지 않는다.
- [ ] Gatekeeper 경고 가능성과 Open Anyway 안내가 포함된다.

## 개인정보 / Local-first

- [ ] 원본 화면 이미지를 저장하지 않는다.
- [ ] OCR 캡처 이미지를 backend로 전송하지 않는다.
- [ ] 원본 오디오 파일을 영구 저장하지 않는다.
- [ ] raw audio buffer를 DB에 저장하지 않는다.
- [ ] AI API Key를 문서, repo, UserDefaults에 저장하지 않는다.
- [ ] AI API Key는 Keychain에 저장한다.
- [ ] raw git diff를 DB/DevEvent/log/report content에 저장하지 않는다.
- [ ] command tracking이 stdout/stderr 전체와 shell history를 저장하지 않는다.

## 수동 문제 재현 시 수집 정보

```bash
uname -m
sw_vers
spctl --assess --verbose /Applications/MwohamMac.app
codesign --verify --deep --strict --verbose=2 /Applications/MwohamMac.app
curl http://127.0.0.1:8765/health
```

## 현재 범위 밖

- 공개 배포용 Developer ID signing/notarization
- 공개 스토어 배포
- 자동 업데이트
- 여러 repo Dev Tracking
- STT 모델 다운로드/교체 UI
- 화자 분리
