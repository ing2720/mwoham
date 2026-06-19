# 지인 테스트용 설치/실행 가이드

이 문서는 내부/지인 테스트용 MwohamMac 앱 실행 가이드입니다. 1차 Release
산출물은 DMG이며, 정식 공개 배포용 Developer ID signing과 notarization은 아직
포함하지 않습니다.

현재 테스트 버전은 `MwohamMac.app` 안에 backend를 번들링하지 않습니다. 앱은
Xcode 없이 실행할 수 있지만, backend 실행을 위해 Python과 uv가 필요합니다.
Local Whisper STT 실행 파일과 `large-v3-turbo` 모델은 DMG의 앱 번들에 포함됩니다.

## 구성

- `MwohamMac.app`: macOS SwiftUI 앱입니다. 메뉴바, 플로팅 위젯, OCR 수집, 회의 전사, 기록 제어를 담당합니다.
- `backend`: FastAPI 로컬 서버입니다. SQLite 저장, 회의 transcript 저장, DevEvent 저장, AI/fallback 리포트, PDF export, 웹 대시보드를 담당합니다.
- backend 기본 주소: `http://127.0.0.1:8765`

## 앱 준비 방식

### DMG로 설치하는 테스터

개발자가 전달한 `Mwoham-0.1.0.dmg`를 엽니다.

1. DMG 안의 `MwohamMac.app`을 `Applications` 바로가기로 드래그합니다.
2. DMG 내부에서 바로 실행하지 말고, Applications 폴더로 옮긴 앱을 실행합니다.
3. macOS가 확인되지 않은 앱 경고를 표시하면, 내부 QA 빌드임을 확인한 뒤 시스템
   설정에서 실행을 허용합니다.
4. 첫 실행 후 접근성, 마이크, 음성 인식, 화면 기록 권한을 허용합니다.
5. 권한을 허용한 뒤 앱을 완전히 종료하고 다시 실행합니다.

앱이 열리지 않는 경우:

1. `MwohamMac.app`을 Applications 폴더로 옮깁니다.
2. 한 번 실행을 시도합니다.
3. 차단되면 시스템 설정 → 개인정보 보호 및 보안으로 이동합니다.
4. 아래쪽 보안 영역에서 `MwohamMac.app` 차단 메시지를 찾습니다.
5. “그래도 열기” 또는 “Open Anyway”를 누릅니다.
6. 다시 앱을 실행합니다.

터미널 방식:

```bash
xattr -dr com.apple.quarantine /Applications/MwohamMac.app
open /Applications/MwohamMac.app
```

주의:

- 본 DMG는 내부 QA/포트폴리오 시연용입니다.
- Developer ID signing/notarization이 적용되지 않아 Gatekeeper 경고가 표시될 수 있습니다.
- 앱은 반드시 DMG 내부에서 바로 실행하지 말고 Applications 폴더로 옮긴 뒤 실행해야 합니다.

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
- 선택 사항: Gemini 또는 OpenAI API key

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

OCR, 활성 창 추적, 회의 전사 검증을 위해 권한 허용이 필요할 수 있습니다.

- 화면 기록 권한
  - OCR 수집에 필요합니다.
  - 시스템 오디오 전사와 회의 전체 전사에도 필요합니다.
  - 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 허용합니다.
- 음성 인식 권한
  - Apple Speech 기반 회의 전사에 필요합니다.
  - 시스템 설정 > 개인정보 보호 및 보안 > 음성 인식에서 허용합니다.
- 마이크 권한
  - 회의 전사 입력에 필요합니다.
  - 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 허용합니다.
- 손쉬운 사용 권한
  - 활성 앱/창 제목 접근 또는 일부 AppKit 기반 추적에서 필요할 수 있습니다.
  - 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 허용합니다.

권한을 허용한 뒤에는 앱을 완전히 종료하고 다시 실행합니다.

회의 전사는 원본 오디오 파일을 저장하지 않고, backend로 audio data를 전송하지 않습니다. backend에는 transcript text만 저장합니다.

회의 전사 source별 권한:

- 마이크: 음성 인식, 마이크
- 시스템 오디오: 음성 인식, 화면 기록
- 회의 전체: 음성 인식, 마이크, 화면 기록

회의 전체는 마이크와 시스템 오디오 입력을 하나의 Apple Speech recognitionTask로
처리하고, 종료 시 로컬 Whisper runtime으로 일괄 전사를 시도합니다.

Release DMG에는 Whisper 실행 파일과 `large-v3-turbo` 모델을 포함하는 것을 기본
정책으로 합니다. 일반 사용자는 별도 STT API key, Homebrew 설치, 모델 다운로드가
필요 없습니다. 설정 화면의 Local Whisper 상태가 `모델 없음` 또는 `실행 파일 없음`
으로 표시되면 배포 파일이 손상됐거나 모델 포함 버전이 아니므로 포함된 배포판으로
다시 설치합니다.

1차 DMG packaging은 Homebrew `whisper-cli`가 참조하는 `libwhisper`, `ggml`,
`libomp` dylib를 앱 번들 안에 함께 넣고 install name을 bundle-local 경로로
수정합니다. static `whisper-cli` 또는 Developer ID notarized runtime은 공개 배포
전 별도 Release 작업입니다.

## Dev Tracking

앱은 개발 도구가 활성화되면 자동으로 backend watcher process를 실행해 Git 변경 상태를 DevEvent로 저장합니다. 별도 시작/종료 버튼은 없습니다.

개발 도구 판단 대상:

- PyCharm
- Visual Studio Code
- Code
- Terminal
- iTerm
- iTerm2
- Cursor

동작:

- 개발 도구 활성화 시 자동 시작
- 비개발 앱 이동 시 grace period 후 종료
- watcher 중복 실행 방지
- 앱 종료 시 watcher 종료
- watcher stdout/stderr를 앱 상태, 메뉴바, 플로팅 위젯에 표시

추적 repo path는 앱 설정 영역에서 1개만 입력할 수 있습니다.

- 비어 있으면 현재 mwoham repo fallback 사용
- repo 검증은 `git rev-parse --show-toplevel` 기준
- 여러 repo 지원 없음
- repo 자동 추정 없음

backend watcher는 raw git diff 본문이나 파일 내용을 저장하지 않습니다. DevEvent에는 Git 상태 요약과 diff_summary 같은 안전한 메타데이터만 저장합니다.

## AI Provider 설정

Release 앱에서는 설정 화면에서 AI Provider를 선택하고 API Key를 입력합니다.
API Key는 macOS Keychain에 저장되며 앱 번들에는 포함되지 않습니다. 연결 테스트
후 사용 가능한 모델 목록을 불러오고, 사용자는 dropdown에서 모델을 선택합니다.
API Key가 없으면 AI 호출 없이 system fallback 리포트가 생성될 수 있습니다.

개발 환경에서는 `backend/.env`로 provider 설정을 override할 수 있습니다.

예시:

```env
AI_PROVIDER="gemini"
AI_MODEL=""
GEMINI_API_KEY="your-api-key"
GEMINI_MODEL="gemini-2.5-flash-lite"
OPENAI_API_KEY=""
OPENAI_MODEL="gpt-5.2-mini"
GEMINI_MAX_OUTPUT_TOKENS="8192"
```

주의:

- API key를 다른 사람에게 공유하지 않습니다.
- 무료 quota를 초과하거나 API 호출에 실패하면 리포트가 placeholder/fallback으로 생성될 수 있습니다.
- `.env`는 개발용 옵션이며 Release 앱 번들에는 실제 API Key를 포함하지 않습니다.
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
7. 개발 도구를 활성화하고 Dev Tracking 상태가 `감시 시작`, `변경 없음`, `Git 변경 감지` 등으로 바뀌는지 확인합니다.
8. 빠른 메모를 저장합니다.
9. 회의 전사 source를 선택해 transcript text 저장을 확인합니다.
10. 기본 타임라인과 상세 타임라인을 확인합니다.
11. 리포트를 생성합니다.
12. PDF export와 다운로드를 확인합니다.

상세 시나리오는 [QA_CHECKLIST.md](QA_CHECKLIST.md)를 참고하세요.

## 자주 보는 확인 명령

```bash
curl http://127.0.0.1:8765/status
curl "http://127.0.0.1:8765/timeline/today?date=$(date +%F)"
curl "http://127.0.0.1:8765/timeline/today/detail?date=$(date +%F)"
curl "http://127.0.0.1:8765/screen-observations?date=$(date +%F)&limit=20"
curl "http://127.0.0.1:8765/activity-segments?date=$(date +%F)"
curl "http://127.0.0.1:8765/dev-events/today?date=$(date +%F)"
curl "http://127.0.0.1:8765/meeting-transcripts/today"
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

- API Key가 없거나 잘못됐을 수 있습니다.
- Provider 무료 quota를 초과했을 수 있습니다.
- 선택한 모델을 계정에서 사용할 수 없을 수 있습니다.

Dev Tracking 오류:

- backend 경로를 찾을 수 없는지 확인합니다.
- repo path가 실제 디렉터리인지 확인합니다.
- `git -C <repoPath> rev-parse --show-toplevel`이 성공하는지 확인합니다.
- uv가 설치되어 있고 앱 실행 환경 PATH에서 찾을 수 있는지 확인합니다.

STT Runtime 없음:

- 설정 화면의 Local Whisper 상태 카드를 확인합니다.
- 일반 사용자는 모델을 직접 설치하지 않고 `large-v3-turbo` 모델이 포함된 배포판을
  다시 설치합니다.
- 개발 환경에서는 `/opt/homebrew/bin/whisper-cli`와
  `~/Library/Application Support/Mwoham/models/ggml-large-v3-turbo.bin` fallback을
  사용할 수 있습니다.
- `whisper-cli`가 있지만 실행 권한 없음으로 표시되면 배포 bundle의 실행 권한을
  확인합니다.

앱 실행이 macOS에서 차단됨:

- 이번 빌드는 내부 테스트용이며 Developer ID signing/notarization이 없습니다.
- Finder 또는 시스템 설정의 보안 안내에서 실행 허용이 필요할 수 있습니다.
