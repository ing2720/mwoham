# Development Index

이 문서는 Mwoham 개발자가 어디서 어떤 문서를 봐야 하는지 안내하는 인덱스입니다. 실행/구조/QA의 상세 내용은 각 전용 문서에 둡니다.

## 프로젝트 구성

- Root README: 프로젝트 소개, 현재 릴리즈 상태, 빠른 설치/실행
- `backend/README.md`: backend 실행, API 구조, DB/migration, 테스트
- `mac-client/README.md`: macOS 앱 구조, 빌드, 권한, STT, Keychain, menu bar/floating widget
- `docs/TESTER_INSTALL_GUIDE.md`: Xcode 없는 테스터 설치 안내
- `docs/QA_CHECKLIST.md`: 내부 QA 체크리스트
- `docs/RELEASE_CHECKLIST.md`: 내부 QA DMG 생성/검증 절차
- `docs/DEV_TRACKING.md`: Git 상태 기반 DevEvent 자동 기록
- `docs/COMMAND_TRACKING.md`: zsh command metadata 기록
- `docs/STT_WHISPER_POC.md`: Local Whisper 회의 전사 정책과 POC
- `docs/SYSTEM_AUDIO_CAPTURE_SPIKE.md`: ScreenCaptureKit 시스템 오디오 전사 구조

## 빠른 backend 실행

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

## 빠른 macOS 앱 실행

```bash
./scripts/build_macos_app.sh --open
```

Release configuration 확인:

```bash
./scripts/build_macos_app.sh --release --open
```

컴파일/UI 확인용 unsigned build:

```bash
./scripts/build_macos_app.sh --unsigned --open
```

권한 QA는 `~/Applications/MwohamMac.app` stable path 기준으로 수행합니다.

## 검증 루틴

backend:

```bash
cd backend
uv run python scripts/run_dev_checks.py --no-record
uv run pytest -q
```

macOS focused checks:

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

공통:

```bash
git diff --check
```

## 개발 원칙

- backend는 `router -> service -> repository` 흐름을 유지합니다.
- 라우터에 DB 쿼리를 직접 작성하지 않습니다.
- 모델 변경이 없으면 migration을 만들지 않습니다.
- macOS app runtime path는 고정 설치 경로가 아니라 `Bundle.main.resourceURL`과 Application Support fallback 기준으로 계산합니다.
- 실제 API Key, `.env`, DB, 모델 파일, `whisper-cli`, dylib 원본을 git에 포함하지 않습니다.
- 원본 화면 이미지, 원본 오디오, raw audio buffer, raw git diff를 저장하지 않습니다.
- AI Provider key는 macOS Keychain에만 저장합니다.
- provider key 없음/API 실패/quota/timeout 상황에서는 fallback report를 유지합니다.

## 문서 작업 원칙

- 프로젝트 소개는 Root README에 둡니다.
- backend 실행/API/DB/테스트는 `backend/README.md`에 둡니다.
- macOS 앱 빌드/권한/STT/Keychain은 `mac-client/README.md`에 둡니다.
- 테스터 설치 안내는 `docs/TESTER_INSTALL_GUIDE.md`에 둡니다.
- 수동 QA는 `docs/QA_CHECKLIST.md`에 둡니다.
- DMG 생성/검증은 `docs/RELEASE_CHECKLIST.md`에 둡니다.
- 공개 배포가 완료된 것처럼 보이는 표현을 쓰지 않습니다.
- 향후 개선은 구현 완료 기능과 분리해서 적습니다.
