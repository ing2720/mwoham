# Mwoham

Mwoham은 macOS 개인 업무 기록, 회의 전사, 일일 리포트 생성을 위한 로컬 우선 앱입니다. macOS SwiftUI 앱이 기록 제어와 수집 UI를 담당하고, 로컬 FastAPI backend가 `127.0.0.1:8765`에서 데이터를 저장/가공합니다.

현재 상태는 v0.1.x 내부 QA/포트폴리오 시연용 DMG 기준입니다. 공개 배포용 Developer ID signing/notarization은 적용하지 않았고, Apple Developer Program 미가입 상태의 internal QA/ad-hoc 성격 빌드로 관리합니다.

## 주요 기능

- 기록 세션 시작, 일시정지, 재개, 종료
- 활성 앱/창 기반 작업 구간 기록
- 화면 OCR 텍스트 수집과 타임라인 반영
- 빠른 메모 저장
- 회의 전사
  - 마이크 입력
  - 시스템 오디오 입력
  - 마이크 + 시스템 오디오 회의 전체 처리
- Local Whisper STT
  - 앱 시작 시 `~/Library/Application Support/Mwoham/stt` 기준으로 런타임 확인
  - DMG 안의 resource는 설치 원본 또는 fallback으로 사용
  - 별도 STT API key 불필요
- Dev Tracking
  - Git snapshot
  - 개발 검증 명령 결과
  - zsh command tracking metadata
  - 개발 도구 활성화 기반 watcher
- Timeline
  - 기본/상세 타임라인
  - DevEvent, 회의, 메모, OCR, 리포트 필터
- Daily Report
  - Gemini/OpenAI 선택 가능
  - API Key는 macOS Keychain 저장
  - key 없음, quota/API 실패, timeout 시 fallback report 생성
- Daily Review Dashboard
- Markdown/PDF export
- macOS Menu Bar
- Floating Widget
- Launch at Login
- 내부 QA용 DMG packaging

## 사용 기술 스택

### Backend

- Runtime: Python 3.12+
- Web framework: FastAPI
- ASGI server: Uvicorn
- ORM: SQLAlchemy
- Migration: Alembic
- Database: SQLite
- Settings: pydantic-settings, `.env`
- Schema validation: Pydantic
- Template rendering: Jinja2
- Web dashboard: FastAPI web routes + Jinja2 templates
- Markdown export: Python Markdown
- PDF export: WeasyPrint
- HTTP client/test utility: httpx
- Package/dependency manager/runtime launcher: uv
- Test framework: pytest, pytest-cov
- Lint: ruff
- Local API security: optional Bearer token via `LOCAL_API_TOKEN`

### Backend Architecture

- API layer: `app/api/endpoints/*`
- Service layer: `app/services/*`
- Repository layer: `app/repositories/*`
- ORM models: `app/models/*`
- Request/response schemas: `app/schemas/*`
- Report/export layer: `app/report/*`
- AI integration layer: `app/ai/*`
- Web UI layer: `app/web/*`
- DB/session layer: `app/db/*`
- Core utilities: config, timezone, security, exceptions

### macOS App / Frontend

- Language: Swift
- UI framework: SwiftUI
- macOS interop: AppKit
- App entry: `WindowGroup` + `MenuBarExtra`
- State pattern: ObservableObject / StateObject / AppStorage / UserDefaults
- Local API client: URLSession 기반 `LocalApiClient`
- Key storage: macOS Keychain
- Menu bar UI: SwiftUI `MenuBarExtra`
- Floating widget: custom floating panel/controller
- Launch at Login: macOS login item integration
- Permission UI: first-run permission onboarding + settings status cards
- Build tool: Xcode / xcodebuild

### macOS System APIs

- Microphone capture: AVFoundation
- Apple Speech fallback: Speech framework
- System audio capture: ScreenCaptureKit
- Screen recording permission: CoreGraphics `CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`
- Accessibility permission: ApplicationServices `AXIsProcessTrusted`, `AXIsProcessTrustedWithOptions`
- App/file opening: NSWorkspace
- Open panel/path selection: NSOpenPanel
- Process lifecycle: Foundation `Process`

### STT / Audio

- Primary local STT: Local Whisper via `whisper-cli`
- Model: `ggml-large-v3-turbo.bin`
- Installed runtime layout: `~/Library/Application Support/Mwoham/stt`
- Bundled install source: `MwohamMac.app/Contents/Resources/STT` 또는 `stt`
- Bundled dynamic libraries: `libwhisper`, `ggml`, `libomp` 계열 dylib
- Runtime dependency rewrite: `install_name_tool`
- Apple Speech fallback: `SFSpeechRecognizer`, `SFSpeechAudioBufferRecognitionRequest`
- Audio conversion/leveling: AVAudioPCMBuffer, AVAudioConverter, RMS/peak level meter
- Audio policy: raw audio 영구 저장 없음, backend audio 전송 없음

### AI / Report

- AI providers: Gemini, OpenAI
- Provider selection: macOS app settings
- API Key storage: macOS Keychain
- Model selection: provider model list / connection test 기반
- Prompt construction: timeline, DevEvent, meeting transcript, memo, OCR context
- Fallback report: API key 없음, quota/API 실패, timeout 시 deterministic fallback
- Report formats: web detail, Markdown, PDF
- Privacy filter: token/password/secret/bearer 계열 문자열 마스킹

### Dev Tracking / Automation

- Git snapshot collection: custom Python scripts
- Command tracking: zsh `preexec` / `precmd` hook
- DevEvent storage: backend API + SQLite
- Watcher process: `watch_dev_context.py`
- Process orchestration: macOS app child process management
- Diff policy: raw diff 저장 없음, diff stat/summary 중심
- Validation runner: `run_dev_checks.py`

### Packaging / Release

- macOS build scripts: shell scripts + xcodebuild
- DMG packaging: `hdiutil`
- App signing checks: `codesign`
- Gatekeeper assessment reference: `spctl`
- Quarantine troubleshooting: `xattr`
- Bundle validation: STT resource check scripts
- Release artifact: internal QA/portfolio `dist/Mwoham-*.dmg`
- Distribution status: Developer ID signing/notarization 없음

### Testing / QA

- Backend unit/integration tests: pytest
- Migration validation: `alembic check`
- Lint/static checks: ruff, `git diff --check`
- macOS presentation harness scripts
- STT runtime readiness script
- AI Provider settings harness
- Floating widget responsive/settings harness
- Menu bar presentation harness
- Launch at Login harness
- Manual QA: tester install guide, QA checklist, release checklist

## 구조

```text
Mwoham
  backend/
    FastAPI, SQLite, SQLAlchemy, Alembic, Timeline/Report service, web dashboard
  mac-client/
    SwiftUI macOS app, STT, permission onboarding, menu bar, floating widget
  scripts/
    macOS build/package/test scripts
  docs/
    tester install, QA, release, tracking, STT notes
```

backend의 기본 흐름은 `router -> service -> repository`입니다. macOS 앱은 `LocalApiClient`를 통해 backend API를 호출하고, component installer가 backend/STT resource를 Application Support 아래에 준비한 뒤 backend lifecycle manager가 앱이 띄운 backend process만 관리합니다.

## Lightweight DMG / Component Installer

v1.1.0 이후 기본 release DMG는 lightweight 구조입니다. DMG에는 `MwohamMac.app` 본체만 넣고, backend/STT CLI/STT model은 앱 실행 후 Settings의 `필수 컴포넌트` 화면에서 별도 설치합니다. 기존 full bundle 방식은 내부 QA fallback으로 유지합니다.

```text
~/Library/Application Support/Mwoham/
  backend/
  stt/
    bin/
      whisper-cli
    lib/
    models/
      ggml-large-v3-turbo.bin
  downloads/
  staging/
  logs/
  data/
  component_manifest.json
```

컴포넌트 처리 기준:

- backend: `~/Library/Application Support/Mwoham/backend`
- STT CLI: `~/Library/Application Support/Mwoham/stt/bin/whisper-cli`
- STT libs: `~/Library/Application Support/Mwoham/stt/lib`
- STT model: `~/Library/Application Support/Mwoham/stt/models/ggml-large-v3-turbo.bin`
- manifest: `component_manifest.json`에 `missing/downloading/installed/failed/version_mismatch/invalid` 상태, version, path, sourceURL, sha256, installedAt, updatedAt, lastError를 기록합니다.

설치 흐름:

1. 앱 시작 시 ComponentInstaller가 manifest와 실제 파일 상태를 확인합니다.
2. backend가 없으면 backend start를 시도하지 않고 `backend 설치 필요` 상태를 표시합니다.
3. 사용자가 Settings에서 전체 설치 또는 개별 설치를 누르면 backend, STT CLI, STT model을 다운로드합니다.
4. 다운로드 파일은 `downloads/`에 저장하고 sha256 검증 후 `staging/`에서 압축 해제/검증합니다.
5. 검증 성공 시에만 최종 경로로 이동합니다. 실패하거나 중단되면 기존 정상 설치본은 유지합니다.
6. backend 설치 후 기존 migration/start/health check 흐름이 실행됩니다.

다운로드 asset 기본 이름:

- `MwohamBackend-1.1.0.tar.gz`
- `MwohamSTTRuntime-1.1.0.tar.gz`
- `ggml-large-v3-turbo.bin`

기본 URL은 GitHub Releases asset 형태로 구성됩니다. `./scripts/build_component_assets.sh`는 `dist/components` 아래 release asset과 `sha256sums.txt`, remote manifest 예시, 앱이 참조하는 `GeneratedComponentSources.swift`를 생성합니다.

```bash
./scripts/build_component_assets.sh --stt-model-path /path/to/ggml-large-v3-turbo.bin
```

모델 원본 경로가 없으면 backend/STT runtime asset만 생성하고 model sha는 비워 둡니다. 이 상태에서는 STT model 설치 버튼이 안전하게 실패합니다. Offline 상태거나 checksum이 설정되지 않으면 설치가 실패하고 Settings에 `lastError`가 표시됩니다.

패키징:

```bash
./scripts/package_macos_dmg.sh --lightweight
./scripts/package_macos_dmg.sh --full
```

- lightweight: app bundle에 `Contents/Resources/backend`, `Contents/Resources/STT`를 포함하지 않습니다.
- full: 기존 내부 QA 방식처럼 backend/STT runtime/model을 bundle resource로 포함합니다.

## Privacy / Local-First 정책

- 원본 화면 이미지는 저장하지 않습니다.
- OCR 캡처 이미지는 backend로 전송하지 않고 메모리에서 텍스트만 추출합니다.
- 원본 오디오와 raw audio buffer는 저장하지 않습니다.
- Local Whisper 처리를 위한 임시 오디오 파일은 처리 후 삭제합니다.
- backend에는 전사 text만 저장합니다.
- STT는 외부 STT API가 아니라 Application Support에 설치된 로컬 Whisper를 우선 사용합니다.
- AI 리포트는 사용자가 Gemini/OpenAI API Key를 입력한 경우에만 provider를 호출합니다.
- AI API Key는 macOS Keychain에 저장하고 repo, `.env`, UserDefaults, 문서에 넣지 않습니다.
- raw git diff, shell history, stdout/stderr 전체, 키 입력 내용은 DevEvent에 저장하지 않습니다.
- command metadata와 report context에는 민감정보 마스킹을 적용합니다.

## 릴리즈 상태

- 대상: 내부 QA/포트폴리오 시연
- 산출물: `dist/Mwoham-1.1.0.dmg` 또는 최신 `dist/Mwoham-*.dmg`
- Bundle ID: `com.ing2720.MwohamMac`
- backend: `http://127.0.0.1:8765`
- health check: `GET /health`
- signing: internal QA/ad-hoc 성격
- Developer ID signing: 현재 범위 밖
- notarization: 현재 범위 밖
- 공개 스토어 배포: 현재 범위 밖
- Gatekeeper 경고: 발생 가능, 설치 가이드에서 안내

## 빠른 설치

테스터는 최신 DMG를 사용합니다.

1. `dist/Mwoham-*.dmg`를 엽니다.
2. `MwohamMac.app`을 DMG 안의 `Applications` 바로가기로 드래그합니다.
3. DMG 내부 앱을 바로 실행하지 말고 Applications로 복사된 앱을 실행합니다.
4. macOS가 차단하면 Finder에서 우클릭 > 열기를 시도합니다.
5. 그래도 차단되면 시스템 설정 > 개인정보 보호 및 보안에서 “그래도 열기” 또는 “Open Anyway”를 누릅니다.
6. 첫 실행 권한 온보딩에서 접근성, 화면 기록, 마이크, 음성 인식을 허용합니다.
7. 화면 기록/접근성 권한 반영이 늦으면 앱을 완전히 종료한 뒤 다시 실행합니다.

터미널 최후 수단:

```bash
xattr -dr com.apple.quarantine /Applications/MwohamMac.app
open /Applications/MwohamMac.app
```

자세한 설치 안내는 [Tester Install Guide](docs/TESTER_INSTALL_GUIDE.md)를 참고하세요.

## 로컬 개발 실행

backend:

```bash
cd backend
uv sync
uv run alembic upgrade head
uv run uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload
```

상태 확인:

```bash
curl http://127.0.0.1:8765/health
curl http://127.0.0.1:8765/status
```

웹 화면:

- http://127.0.0.1:8765/dashboard
- http://127.0.0.1:8765/timeline
- http://127.0.0.1:8765/timeline/detail
- http://127.0.0.1:8765/reports
- http://127.0.0.1:8765/settings

macOS 앱:

```bash
./scripts/build_macos_app.sh --open
./scripts/build_macos_app.sh --release --open
```

개발/권한 QA의 stable app path는 `~/Applications/MwohamMac.app`입니다. 앱 runtime resource는 고정 설치 경로가 아니라 `Bundle.main.resourceURL`과 Application Support fallback 기준으로 탐색합니다.

backend 실행에는 packaged `.venv`가 없을 경우 `uv`가 필요할 수 있습니다. Finder/DMG/LaunchServices로 실행한 앱은 shell PATH를 그대로 상속하지 않을 수 있으므로 macOS 앱은 `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.cargo/bin`, Python framework 경로를 추가로 탐색합니다.

```bash
brew install uv
which uv
uv --version
```

macOS 앱 개발 자세한 내용은 [mac-client README](mac-client/README.md)를 참고하세요.

## Backend 개발

backend 환경 설정은 `backend/.env.example`을 참고합니다. 실제 `.env`, API Key, DB, export 산출물은 git에 포함하지 않습니다.

주요 명령:

```bash
cd backend
uv run ruff check .
uv run pytest
uv run alembic check
git diff --check
uv run python scripts/run_dev_checks.py --no-record
```

backend 구조와 API/DB 개발 기준은 [backend README](backend/README.md)를 참고하세요.

## 내부 QA 검증

문서 작업 또는 기능 작업 후 주요 smoke/regression:

```bash
./scripts/test_macos_stt_runtime_readiness.sh
./scripts/test_macos_ai_provider_settings.sh
./scripts/test_macos_report_presentation.sh
./scripts/test_macos_timeline_presentation.sh
./scripts/test_macos_floating_widget_settings.sh
./scripts/test_macos_floating_widget_responsive.sh
./scripts/test_macos_menu_bar_floating_presentation.sh
./scripts/test_macos_launch_at_login.sh

cd backend
uv run python scripts/run_dev_checks.py --no-record
uv run pytest -q
```

전체 수동 QA는 [QA Checklist](docs/QA_CHECKLIST.md)를 참고하세요.

## DMG 릴리즈 생성

내부 QA/포트폴리오 시연용 DMG:

```bash
./scripts/package_macos_dmg.sh --version 1.1.0 --internal-qa
```

검증 대상:

- `dist/Mwoham-*.dmg`
- DMG 안의 `MwohamMac.app`
- DMG 안의 `Applications` 바로가기
- DMG 안의 `README_INSTALL.md`
- bundled STT runtime/model/dylib
- Gatekeeper 안내

자세한 절차는 [Release Checklist](docs/RELEASE_CHECKLIST.md)를 참고하세요.

## 현재 한계

- 내부 QA/포트폴리오 시연용 빌드이며 공개 배포가 아닙니다.
- Developer ID signing/notarization은 아직 적용하지 않았습니다.
- Gatekeeper 경고가 표시될 수 있습니다.
- 화면 기록/접근성 권한은 macOS 정책상 사용자가 직접 허용해야 합니다.
- 권한 허용 후 앱 재시작이 필요할 수 있습니다.
- 자동 업데이트 채널은 없습니다.
- 여러 repo Dev Tracking, STT 모델 다운로드/교체 UI는 아직 없습니다.

## 향후 개선 후보

- Developer ID signing/notarization
- 자동 업데이트
- STT 모델 다운로드/교체 UI
- report quality refinement
- timeline clustering refinement
- 권한/서명/앱 경로 진단 복사 기능
- public release guide

## 문서

- [Tester Install Guide](docs/TESTER_INSTALL_GUIDE.md)
- [QA Checklist](docs/QA_CHECKLIST.md)
- [Release Checklist](docs/RELEASE_CHECKLIST.md)
- [Backend README](backend/README.md)
- [macOS Client README](mac-client/README.md)
- [Dev Tracking](docs/DEV_TRACKING.md)
- [Command Tracking](docs/COMMAND_TRACKING.md)
- [STT Whisper POC](docs/STT_WHISPER_POC.md)
- [System Audio Capture](docs/SYSTEM_AUDIO_CAPTURE_SPIKE.md)
- [Development Index](DEVELOPMENT.md)

## Git 제외 대상

- `backend/.env`
- `backend/.venv/`
- `backend/data/`
- `backend/exports/`
- SQLite DB 파일
- `dist/`
- `.derivedData/`
- coverage/cache 산출물
- 모델 파일, `whisper-cli`, bundled dylib 원본
