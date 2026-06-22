# Release Checklist

이 문서는 Mwoham v0.1.x 내부 QA/포트폴리오 시연용 DMG를 다시 만들고 검증하는 절차입니다. 현재 릴리즈는 공개 배포용 Developer ID signing/notarization을 포함하지 않습니다.

## 범위

이번 릴리즈 절차가 하는 일:

- `MwohamMac.app` Release build 생성
- Local Whisper runtime/model/dylib를 앱 번들 설치 원본으로 포함
- 앱 실행 후 Application Support component 설치/검증
- `MwohamMac.app`, `Applications` symlink, `README_INSTALL.md`를 DMG에 포함
- STT resource 검증
- app signing/ad-hoc internal QA 처리
- DMG 생성 및 verify

이번 릴리즈 절차가 하지 않는 일:

- backend API 변경
- DB/schema/migration 변경
- STT runtime resolver 정책 변경
- AI Provider Keychain 정책 변경
- recording/timeline/report semantics 변경
- Launch at Login 정책 변경
- 공개 배포용 Developer ID signing
- notarization/stapling
- 공개 스토어 배포

## 사전 확인

- 실제 API Key, `.env`, DB, export 산출물이 git에 들어가지 않았는지 확인
- 모델 파일, `whisper-cli`, dylib 원본이 git 변경 목록에 들어가지 않았는지 확인
- `dist/` 산출물은 git에 포함하지 않음
- 변경 내용이 문서/패키징 의도와 맞는지 확인

```bash
git status --short
git diff --check
```

## DMG 생성

현재 내부 QA 기준:

```bash
./scripts/package_macos_dmg.sh --version 1.1.0 --internal-qa
```

최신 버전을 만들 때는 `--version`만 올립니다.

예상 산출물:

```text
dist/Mwoham-1.1.0.dmg
```

또는 최신:

```text
dist/Mwoham-*.dmg
```

## STT Runtime Policy

현재 full/internal QA Release app에는 다음 resource가 설치 원본으로 포함되어야 합니다.

```text
MwohamMac.app/Contents/Resources/STT/whisper-cli
MwohamMac.app/Contents/Resources/STT/models/ggml-large-v3-turbo.bin
MwohamMac.app/Contents/Resources/STT/lib/*.dylib
```

앱 실행 후 실제 우선 사용 위치:

```text
~/Library/Application Support/Mwoham/stt/bin/whisper-cli
~/Library/Application Support/Mwoham/stt/models/ggml-large-v3-turbo.bin
~/Library/Application Support/Mwoham/stt/lib/*.dylib
```

Homebrew 기반 `whisper-cli`는 단독 실행 파일이 아니므로 필요한 `libwhisper`, `ggml`, `libomp` 계열 dylib를 앱 번들에 함께 넣고 `install_name_tool`로 bundle-local 경로를 사용하게 정리합니다.

## Component Install Policy

앱 번들 내부 Resources는 읽기 전용 설치 원본입니다. runtime 쓰기 위치, manifest, DB, log는 Application Support 아래에 둡니다.

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

검증 기준:

- backend가 포함된 배포판이면 `Application Support/Mwoham/backend`로 복사되어야 합니다.
- STT CLI가 포함된 배포판이면 `Application Support/Mwoham/stt/bin/whisper-cli`가 executable이어야 합니다.
- STT model이 포함되지 않은 lite 배포판은 앱이 종료되지 않고 manifest/status에 `missing`으로 표시되어야 합니다.
- Release 기본값에 개발자 개인 로컬 backend 경로가 들어가면 안 됩니다.
- packaged backend에 `.venv/bin/python`과 `.venv/bin/alembic`이 있으면 앱은 `uv` 없이 해당 실행 파일을 우선 사용해야 합니다.
- `.venv`가 없는 배포판은 backend 실행에 `uv`가 필요할 수 있으며, 앱은 Finder 실행 환경을 고려해 `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.cargo/bin`, Python framework 경로를 탐색해야 합니다.
- `backend_payload.zip`, `stt_cli_payload.zip`, remote download, lite/full DMG 분리는 향후 확장 지점입니다.

`uv` 확인:

```bash
which uv
uv --version
```

## 자동 검증

설치된 앱 기준:

```bash
APP="/Applications/MwohamMac.app"
./scripts/check_release_stt_resources.sh "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority|Runtime|Signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep com.apple.security.device.audio-input
```

DMG 검증:

```bash
hdiutil verify dist/Mwoham-1.1.0.dmg
```

최신 DMG를 자동 선택하려면:

```bash
DMG="$(ls -t dist/Mwoham-*.dmg | head -1)"
hdiutil verify "$DMG"
```

focused regression:

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

## DMG 수동 확인

1. `dist/Mwoham-*.dmg` mount
2. DMG 안에 `MwohamMac.app` 존재 확인
3. DMG 안에 `Applications` symlink 존재 확인
4. DMG 안에 `README_INSTALL.md` 존재 확인
5. `MwohamMac.app`을 Applications로 드래그
6. DMG 내부 앱이 아니라 복사된 앱 실행
7. Gatekeeper 차단 시 시스템 설정 > 개인정보 보호 및 보안 > Open Anyway 확인
8. 권한 온보딩 확인
9. `/health` 연결 확인
10. `~/Library/Application Support/Mwoham/component_manifest.json` 생성 확인
11. Settings에서 Local Whisper runtime/model source 확인
12. 회의 전사 시작/저장 확인
13. Timeline 화면 확인
14. AI Key 없이 fallback report 생성 확인
15. AI Key가 있으면 AI report 생성 확인
16. Menu bar/Floating widget 확인
17. Launch at Login toggle 확인
18. 앱 종료/재실행 후 권한 상태가 유지되는지 확인

## 배포 전 확인

- DMG 파일명과 버전이 맞는지 확인
- DMG 용량이 모델 포함 기준으로 비정상적으로 작지 않은지 확인
- `README_INSTALL.md`가 포함되어 있는지 확인
- Applications symlink가 포함되어 있는지 확인
- STT model이 포함되어 있는지 확인
- `whisper-cli` 실행 권한이 있는지 확인
- Homebrew absolute dylib dependency가 남아 있지 않은지 확인
- Application Support component manifest가 생성되는지 확인
- backend/STT runtime이 앱 번들 내부를 쓰기 위치로 사용하지 않는지 확인
- app bundle이 DMG 내부 실행이 아니라 복사 실행을 안내하는지 확인
- Gatekeeper 경고와 Open Anyway 안내가 문서에 있는지 확인

## GitHub Release 첨부

내부 QA/포트폴리오 시연용으로 GitHub Release를 만들 경우:

1. tag를 생성합니다. 예: `v1.1.0-internal`
2. Release title에 internal QA 성격을 명시합니다.
3. `dist/Mwoham-*.dmg`를 첨부합니다.
4. release note에 Developer ID/notarization 미적용과 Gatekeeper 경고 가능성을 명시합니다.
5. TESTER_INSTALL_GUIDE 링크를 포함합니다.

## ad-hoc/internal QA 한계

- `spctl --assess`는 Developer ID/notarized 배포 기준을 포함하므로 internal QA/ad-hoc build에서 거부될 수 있습니다.
- 이 상태를 공개 배포 통과로 해석하지 않습니다.
- Apple Developer Program 가입 전까지 Developer ID signing/notarization은 현재 범위 밖입니다.
- Gatekeeper 경고는 정상적인 한계로 설치 가이드에서 안내합니다.

## 향후 Public Release 후보

- Developer ID Application signing
- notarization/stapling
- `spctl --assess` acceptance criteria
- 자동 업데이트
- STT 모델 다운로드/교체 UI
- backend/STT 추가 다운로드 installer
- lite/full DMG 분리
- public release guide
