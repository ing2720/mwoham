# Mwoham macOS Client

MwohamMac은 로컬 FastAPI backend와 연결되는 macOS SwiftUI 앱입니다. 일반 창, 메뉴바, 플로팅 위젯에서 기록 상태를 확인하고, 빠른 메모, OCR, 회의 전사, Dev Tracking, AI Provider 설정을 제공합니다.

현재 macOS 앱은 v0.1.x 내부 QA/포트폴리오 시연용 DMG 기준입니다. 공개 배포용 Developer ID signing/notarization은 적용하지 않았습니다.

## 기본 정보

- App name: `MwohamMac`
- Bundle ID: `com.ing2720.MwohamMac`
- Backend URL: `http://127.0.0.1:8765`
- Health check: `GET /health`
- 개발/권한 QA stable path: `~/Applications/MwohamMac.app`
- 내부 QA DMG 설치 path: `/Applications/MwohamMac.app`

## 앱 구조

```text
MwohamMac/
  MwohamMacApp.swift                 WindowGroup + MenuBarExtra
  ContentView.swift                  main navigation and settings
  LocalApiClient.swift               backend API client
  BackendLifecycleManager.swift      backend health/start/stop/restart
  MeetingTranscriptionViewModel.swift
  STTRuntimeResolver.swift
  MwohamPaths.swift
  ComponentManifest.swift
  ComponentInstaller.swift
  LocalWhisperMeetingTranscriber.swift
  PermissionOnboardingView.swift
  PermissionSettingsOpener.swift
  LaunchAtLoginManager.swift
  FloatingWidgetController.swift
  AIProviderSettingsStore.swift
  AIProviderKeychainStore.swift
```

주요 흐름:

```text
SwiftUI View
  -> ViewModel / Manager
  -> LocalApiClient
  -> FastAPI backend
  -> SQLite / Timeline / Report
```

## 주요 기능

- backend 연결 상태 표시
- 앱이 시작한 backend process lifecycle 관리
- recording start/pause/resume/stop
- active app/window tracking
- OCR collection
- quick memo
- meeting transcription
- Local Whisper STT
- Apple Speech fallback
- AI Provider selection
- API Key Keychain storage
- permission status and first-run onboarding
- menu bar status/actions
- floating widget
- Launch at Login
- backend directory override

## Backend lifecycle

앱은 먼저 `http://127.0.0.1:8765/health`를 확인합니다. backend가 없으면 `BackendLifecycleManager`가 다음 후보에서 backend directory를 찾고, `uv run uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload`로 실행합니다.

backend directory 탐색:

1. UserDefaults/AppStorage override
2. `MWOHAM_BACKEND_DIRECTORY`
3. `~/Library/Application Support/Mwoham/backend`
4. `Bundle.main.resourceURL/backend`
5. debug build fallback

앱은 자신이 시작한 backend process만 종료/재시작합니다. 외부에서 이미 실행 중인 backend는 사용자가 직접 관리합니다.

포트 충돌 확인:

```bash
lsof -ti :8765
lsof -ti :8765 | xargs kill -9
```

## 빌드

개발/권한 QA:

```bash
./scripts/build_macos_app.sh --open
```

Release configuration 확인:

```bash
./scripts/build_macos_app.sh --release --open
```

서명 없이 컴파일/UI 확인:

```bash
./scripts/build_macos_app.sh --unsigned --open
```

주의:

- unsigned build는 TCC 권한 유지 QA에 사용하지 않습니다.
- signed 실패 시 unsigned로 자동 전환하지 않습니다.
- 개발/권한 QA는 stable app path인 `~/Applications/MwohamMac.app` 기준으로 수행합니다.
- Xcode DerivedData 앱에 권한을 부여하면 path/identity가 바뀌어 권한이 흔들릴 수 있습니다.

## DMG packaging 연계

내부 QA/포트폴리오 시연용 DMG는 repo root에서 생성합니다.

```bash
./scripts/package_macos_dmg.sh --version 0.1.1 --internal-qa
```

package script는 다음을 처리합니다.

- Release app build
- STT resource 복사
- bundled dylib install name 정리
- STT resource check
- app re-sign
- DMG 생성
- `hdiutil verify`

공개 배포용 Developer ID signing/notarization은 현재 범위 밖입니다.

## macOS 권한

앱이 사용하는 권한:

- 접근성: 활성 창 제목/상태 추적 정확도 향상
- 화면 기록: OCR, 시스템 오디오, 회의 전체 전사
- 마이크: 마이크/회의 전체 전사
- 음성 인식: Apple Speech fallback

첫 실행 시 `PermissionOnboardingView`가 권한 상태를 보여주고, 가능한 권한은 앱에서 직접 요청합니다.

- 마이크: `AVCaptureDevice.requestAccess`
- 음성 인식: `SFSpeechRecognizer.requestAuthorization`
- 화면 기록: `CGRequestScreenCaptureAccess`
- 접근성: `AXIsProcessTrustedWithOptions(prompt: true)`

권한 초기화:

```bash
tccutil reset All com.ing2720.MwohamMac
```

화면 기록과 접근성은 허용 후 앱 재시작이 필요할 수 있습니다.

## App Translocation 주의

DMG 내부 앱을 바로 실행하거나 quarantine 상태의 앱을 실행하면 macOS가 App Translocation 경로에서 앱을 실행할 수 있습니다. 이 경우 권한과 resource path가 예상과 달라질 수 있습니다.

원칙:

- DMG 내부에서 바로 실행하지 않습니다.
- `/Applications` 또는 개발 stable path로 복사한 앱을 실행합니다.
- runtime/resource는 고정 앱 경로가 아니라 `Bundle.main.resourceURL` 기준으로 계산합니다.
- backend/STT path에 개발자 개인 경로를 production default로 넣지 않습니다.

## Component Installer

앱 시작 시 `ComponentInstaller`가 사용자별 Application Support 위치를 준비합니다. 앱 번들 Resources는 읽기 전용 설치 원본으로만 보고, 실제 실행 파일과 모델은 Application Support 아래에서 우선 사용합니다.

```text
~/Library/Application Support/Mwoham/
  backend/
  stt/
    bin/
    lib/
    models/
  logs/
  data/
  component_manifest.json
```

설치/검증 순서:

1. `MwohamPaths.ensureDirectories()`
2. `component_manifest.json` load or create
3. backend resolve/copy
4. STT CLI resolve/copy
5. STT model existence check
6. manifest update
7. backend lifecycle start
8. `/health` readiness check

현재 zip payload 자동 해제와 원격 다운로드는 구현하지 않았습니다. `backend_payload.zip`, `stt_cli_payload.zip`, lite/full DMG 분리는 향후 확장 지점입니다.

## STT runtime

Release DMG는 Local Whisper runtime을 앱 번들에 설치 원본으로 포함할 수 있습니다. 실행 시에는 Application Support에 설치된 runtime을 우선 사용합니다.

```text
~/Library/Application Support/Mwoham/stt/bin/whisper-cli
~/Library/Application Support/Mwoham/stt/models/ggml-large-v3-turbo.bin
~/Library/Application Support/Mwoham/stt/lib/*.dylib
```

runtime 탐색 순서:

1. Application Support
2. 사용자 설정 override
3. bundled resource fallback
4. 개발환경 fallback

STT 정책:

- 일반 테스터는 별도 STT API key가 필요 없습니다.
- 모델 파일, `whisper-cli`, dylib 원본은 repo에 커밋하지 않습니다.
- 모델이 없으면 앱 전체를 종료하지 않고 Local Whisper 상태에 모델 미설치로 표시합니다.
- 원본 오디오는 영구 저장하지 않습니다.
- Local Whisper용 임시 파일은 처리 후 삭제합니다.
- backend에는 transcript text만 저장합니다.

## AI Provider / Keychain

설정 화면에서 Gemini 또는 OpenAI를 선택할 수 있습니다.

- Provider/model: UserDefaults
- API Key: macOS Keychain
- Keychain service: `com.ing2720.MwohamMac.ai-provider`
- key 없음/API 실패/quota 초과/timeout: backend fallback report
- 저장 후 key 전체 값은 다시 표시하지 않고 masked summary만 표시

앱이 backend를 새로 시작할 때 선택한 provider/model/key를 process environment로 주입합니다. 이미 외부에서 실행 중인 backend에는 자동 주입되지 않으므로, 외부 backend는 직접 재시작해야 합니다.

## Menu Bar / Floating Widget

Menu bar와 floating widget은 같은 presentation model을 공유합니다.

표시 항목:

- backend 상태
- recording 상태/시간
- 현재 앱/창
- OCR 상태
- Dev Tracking 상태
- meeting mode

Floating widget 설정:

- opacity
- color preset
- 표시 항목 ON/OFF
- 빠른 액션 ON/OFF
- 기본값 초기화

설정은 UserDefaults에 저장됩니다.

## Launch at Login

설정 화면에서 로그인 시 자동 실행을 켜고 끌 수 있습니다.

정책:

- macOS 로그인 시 앱 실행만 담당합니다.
- recording session은 자동 시작하지 않습니다.
- 앱 경로 진단은 실행 가능한 `.app` bundle과 App Translocation 여부를 기준으로 합니다.

## Dev Tracking

앱은 개발 도구가 활성화되면 backend watcher process를 자동 실행합니다.

대상 앱:

- PyCharm
- Visual Studio Code
- Code
- Terminal
- iTerm
- iTerm2
- Cursor

실행 명령:

```bash
cd backend
uv run python scripts/watch_dev_context.py --repo-path <repo> --interval 60 --session-current
```

raw git diff와 파일 내용은 저장하지 않습니다.

## macOS client 검증

```bash
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

컴파일만 확인:

```bash
xcodebuild \
  -project mac-client/MwohamMac/MwohamMac.xcodeproj \
  -scheme MwohamMac \
  -destination platform=macOS \
  -derivedDataPath /tmp/MwohamMacDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 현재 범위 밖

- Developer ID signing/notarization
- 공개 스토어 배포
- 자동 업데이트
- 여러 repo Dev Tracking
- STT 모델 다운로드/교체 UI
- 화자 분리
- floating widget 위치 저장 고도화
