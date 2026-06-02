# 지인 테스트용 설치/실행 가이드

이 문서는 내부/지인 테스트용 MwohamMac 앱 실행 가이드입니다. 정식 배포용 signing, notarization, DMG 배포는 아직 포함하지 않습니다.

현재 테스트 버전은 `MwohamMac.app` 안에 backend를 번들링하지 않습니다. 앱은 Xcode 없이 실행할 수 있지만, backend 실행을 위해 Python과 uv가 필요합니다.

## 구성

- `MwohamMac.app`: macOS SwiftUI 앱입니다. 메뉴바, 플로팅 위젯, OCR 수집, 기록 제어를 담당합니다.
- `backend`: FastAPI 로컬 서버입니다. SQLite 저장, Gemini 리포트, PDF export, 웹 대시보드를 담당합니다.
- backend 기본 주소: `http://127.0.0.1:8765`

## 앱 준비 방식

### Xcode가 없는 테스터

직접 앱을 생성하지 않습니다. 개발자가 만든 `dist/MwohamMacTesterBundle.zip`을 받아 압축을 풀고, 안에 있는 `MwohamMac.app`을 실행합니다.

Xcode가 없어도 앱 실행은 가능합니다. 단, backend 실행을 위해 Python과 uv는 필요합니다.

### Xcode가 있는 개발자/테스터

저장소에서 직접 테스트 번들을 만들 수 있습니다. 이 단계는 `MwohamMac.app`을 생성하는 단계라 full Xcode가 필요합니다.

```bash
chmod +x scripts/build_macos_release.sh scripts/package_tester_bundle.sh
./scripts/package_tester_bundle.sh
```

생성 결과:

- `dist/MwohamMacTesterBundle/MwohamMac.app`
- `dist/MwohamMacTesterBundle/TESTER_INSTALL_GUIDE.md`
- `dist/MwohamMacTesterBundle/QA_CHECKLIST.md`
- `dist/MwohamMacTesterBundle.zip`

`dist/` 산출물은 git에 포함하지 않습니다.

Release 앱만 빌드하려면:

```bash
chmod +x scripts/build_macos_release.sh
./scripts/build_macos_release.sh
```

스크립트가 출력하는 `MwohamMac.app` 경로를 확인합니다.

## 테스터 준비물

- macOS
- Python
- uv
- backend 소스 폴더
- 전달받은 `MwohamMac.app`
- 선택 사항: Gemini API key

Xcode가 없는 테스터는 개발자에게 `MwohamMacTesterBundle.zip`을 직접 받아서 사용합니다. 저장소를 직접 받아 `scripts/package_tester_bundle.sh`로 앱을 생성하려면 full Xcode가 필요합니다.

## backend 실행

터미널에서 backend 폴더로 이동합니다.

```bash
cd backend
uv sync
uv run alembic upgrade head
uv run uvicorn app.main:app --host 127.0.0.1 --port 8765
```

정상 확인:

```bash
curl http://127.0.0.1:8765/health
curl http://127.0.0.1:8765/status
```

브라우저 확인:

- 대시보드: http://127.0.0.1:8765/dashboard
- 기본 타임라인: http://127.0.0.1:8765/timeline
- 상세 타임라인: http://127.0.0.1:8765/timeline/detail
- 리포트: http://127.0.0.1:8765/reports

## MwohamMac.app 실행

1. backend가 `http://127.0.0.1:8765`에서 실행 중인지 확인합니다.
2. 전달받은 `MwohamMac.app`을 실행합니다.
3. macOS가 확인되지 않은 앱 경고를 표시하면, 내부 테스트 앱임을 확인한 뒤 시스템 설정에서 실행을 허용합니다.
4. 앱 일반 창 또는 메뉴바에서 백엔드 연결 상태가 연결됨으로 표시되는지 확인합니다.
5. 메뉴바에서 플로팅 위젯을 열고 닫아봅니다.

## macOS 권한

OCR과 활성 창 추적 검증을 위해 권한 허용이 필요할 수 있습니다.

- 화면 기록 권한
  - OCR 수집에 필요합니다.
  - 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 허용합니다.
- 시스템 오디오 녹음 권한
  - 현재 MVP에서는 마이크/음성 전사를 본격 사용하지 않습니다.
  - macOS가 권한을 요청하면 테스트 목적에 맞게 허용 여부를 결정합니다.
- 손쉬운 사용 권한
  - 활성 앱/창 제목 접근 또는 일부 AppKit 기반 추적에서 필요할 수 있습니다.
  - 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 허용합니다.

권한을 허용한 뒤에는 앱을 완전히 종료하고 다시 실행합니다.

## Gemini 설정

backend는 `backend/.env`를 읽습니다. Gemini API key가 없으면 Gemini 호출 없이 system fallback 리포트가 생성될 수 있습니다.

예시:

```env
GEMINI_API_KEY="your-api-key"
GEMINI_MODEL="gemini-2.5-flash-lite"
GEMINI_MAX_OUTPUT_TOKENS="8192"
```

주의:

- API key를 다른 사람에게 공유하지 않습니다.
- 무료 quota를 초과하면 Gemini 리포트가 placeholder/fallback으로 생성될 수 있습니다.
- 현재 기본 모델은 `gemini-2.5-flash-lite`입니다.
- 개별 화면 관찰 AI 해석은 quota 절약을 위해 기본 비활성화되어 있습니다.

## Local API Token

테스트 편의를 위해 `LOCAL_API_TOKEN`을 설정하지 않으면 로컬 보호 API 인증이 비활성화됩니다.

`LOCAL_API_TOKEN`을 설정하는 경우:

- backend `.env`의 `LOCAL_API_TOKEN` 값과 Mac 앱 실행 환경의 `LOCAL_API_TOKEN` 값이 같아야 합니다.
- 값이 맞지 않으면 Mac 앱에서 백엔드 연결 실패 또는 API 호출 실패가 발생합니다.

초기 지인 테스트에서는 특별한 이유가 없으면 `LOCAL_API_TOKEN`을 비워두는 방식을 권장합니다.

## 기본 테스트 흐름

1. backend를 실행합니다.
2. `MwohamMac.app`을 실행합니다.
3. 앱에서 기록 시작을 누릅니다.
4. Chrome, PyCharm, Xcode 등 몇 가지 앱으로 전환합니다.
5. PrivateApp으로 등록한 앱을 켜고 UI가 `비공개 앱`으로 표시되는지 확인합니다.
6. OCR 상태가 `OCR 저장됨`, `OCR 텍스트 부족`, `권한 필요` 등 상황에 맞게 표시되는지 확인합니다.
7. 빠른 메모를 저장합니다.
8. 기본 타임라인과 상세 타임라인을 확인합니다.
9. 리포트를 생성합니다.
10. PDF export와 다운로드를 확인합니다.

상세 시나리오는 [QA_CHECKLIST.md](QA_CHECKLIST.md)를 참고하세요.

## 자주 보는 확인 명령

```bash
curl http://127.0.0.1:8765/status
curl "http://127.0.0.1:8765/timeline/today?date=$(date +%F)"
curl "http://127.0.0.1:8765/timeline/today/detail?date=$(date +%F)"
curl "http://127.0.0.1:8765/screen-observations?date=$(date +%F)&limit=20"
curl "http://127.0.0.1:8765/activity-segments?date=$(date +%F)"
curl "http://127.0.0.1:8765/reports/today?date=$(date +%F)"
```

## 문제 해결

백엔드 연결 실패:

- backend가 실행 중인지 확인합니다.
- 포트가 `8765`인지 확인합니다.
- `LOCAL_API_TOKEN` 설정이 Mac 앱과 backend에서 일치하는지 확인합니다.

OCR이 저장되지 않음:

- 기록 상태가 active인지 확인합니다.
- 화면 기록 권한을 허용했는지 확인합니다.
- PrivateApp 또는 MwohamMac 자기 자신이 활성 상태인지 확인합니다.
- 같은 화면 반복으로 중복 저장이 생략됐을 수 있습니다.

리포트가 system fallback으로 생성됨:

- `GEMINI_API_KEY`가 없거나 잘못됐을 수 있습니다.
- Gemini 무료 quota를 초과했을 수 있습니다.
- `GEMINI_MODEL`이 계정에서 사용할 수 없는 모델일 수 있습니다.

앱 실행이 macOS에서 차단됨:

- 이번 빌드는 내부 테스트용이며 Developer ID signing/notarization이 없습니다.
- Finder 또는 시스템 설정의 보안 안내에서 실행 허용이 필요할 수 있습니다.
