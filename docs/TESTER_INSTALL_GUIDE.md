# Tester Install Guide

이 문서는 Xcode 없이 Mwoham을 설치해 보는 내부 QA/포트폴리오 시연용 안내입니다. 현재 배포물은 공개 배포용 앱이 아니며 Developer ID signing/notarization이 적용되지 않았습니다.

## 테스트 대상

- 최신 DMG: `dist/Mwoham-0.1.1.dmg` 또는 최신 `dist/Mwoham-*.dmg`
- 앱: `MwohamMac.app`
- Bundle ID: `com.ing2720.MwohamMac`
- backend: 앱이 로컬 `http://127.0.0.1:8765`에서 사용
- STT: 앱 번들에 포함된 Local Whisper
- AI Report: Gemini/OpenAI API Key를 설정한 경우 provider 사용, 없거나 실패하면 fallback report

## 설치

1. 개발자가 전달한 최신 `Mwoham-*.dmg`를 엽니다.
2. DMG 안의 `MwohamMac.app`을 `Applications` 바로가기로 드래그합니다.
3. DMG 내부에서 바로 실행하지 말고 Applications 폴더로 복사된 앱을 실행합니다.
4. macOS가 확인되지 않은 앱 경고를 표시하면 내부 QA/포트폴리오 시연용 빌드인지 확인한 뒤 실행을 허용합니다.
5. 첫 실행 권한 온보딩에서 필요한 권한을 허용합니다.
6. 화면 기록/접근성 권한을 허용한 뒤에는 앱을 완전히 종료하고 다시 실행합니다.

## Gatekeeper 경고 처리

현재 빌드는 Developer ID notarized app이 아니므로 Gatekeeper 경고가 표시될 수 있습니다.

우선 시도:

1. Finder에서 `/Applications/MwohamMac.app`을 우클릭합니다.
2. `열기`를 선택합니다.
3. 경고창에서 다시 `열기`를 선택합니다.

그래도 안 열리면:

1. 한 번 실행을 시도해 차단 메시지가 나오게 합니다.
2. 시스템 설정 > 개인정보 보호 및 보안으로 이동합니다.
3. 아래쪽 보안 영역에서 `MwohamMac.app` 차단 메시지를 찾습니다.
4. “그래도 열기” 또는 “Open Anyway”를 누릅니다.
5. 앱을 다시 실행합니다.

터미널 최후 수단:

```bash
xattr -dr com.apple.quarantine /Applications/MwohamMac.app
open /Applications/MwohamMac.app
```

## 권한 허용

앱 첫 실행 시 권한 온보딩이 표시됩니다. 권한은 시스템 설정에서 사용자가 직접 허용해야 하며, macOS 정책상 앱이 자동으로 켤 수 없습니다.

필요 권한:

- 접근성: 활성 창 제목/상태 추적 정확도 향상
- 화면 기록: OCR, 시스템 오디오, 회의 전체 전사
- 마이크: 마이크/회의 전체 전사
- 음성 인식: Apple Speech fallback

권한 위치:

- 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용
- 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록
- 시스템 설정 > 개인정보 보호 및 보안 > 마이크
- 시스템 설정 > 개인정보 보호 및 보안 > 음성 인식

권한이 꼬였을 때 개발/QA용 초기화:

```bash
tccutil reset All com.ing2720.MwohamMac
```

초기화 후 앱을 다시 실행하고 권한을 다시 허용합니다.

## Local Whisper STT

일반 테스터는 별도 STT API Key, Homebrew 설치, 모델 다운로드가 필요 없습니다.

DMG 안의 앱 번들에는 다음이 포함됩니다.

```text
MwohamMac.app/Contents/Resources/STT/whisper-cli
MwohamMac.app/Contents/Resources/STT/models/ggml-large-v3-turbo.bin
MwohamMac.app/Contents/Resources/STT/lib/*.dylib
```

회의 전사 정책:

- 원본 오디오는 영구 저장하지 않습니다.
- Local Whisper 처리용 임시 파일은 처리 후 삭제합니다.
- backend에는 transcript text만 저장합니다.
- STT resource가 없거나 실행 권한이 없으면 설정 화면의 Local Whisper 상태 카드에 표시됩니다.

## AI Report

AI Report를 사용하려면 앱 설정에서 Gemini 또는 OpenAI Provider를 선택하고 API Key를 입력합니다.

- API Key는 macOS Keychain에 저장됩니다.
- API Key는 앱 번들, 문서, repo에 포함되지 않습니다.
- Key가 없거나 잘못됐거나 quota/API/네트워크 문제가 있으면 fallback report가 생성됩니다.
- fallback report는 실패가 아니라 provider를 쓰지 못한 상황에서 기본 리포트를 생성하는 안전장치입니다.

## 기본 테스트 흐름

1. `MwohamMac.app` 실행
2. 권한 온보딩 확인
3. backend 연결 상태가 `연결됨`인지 확인
4. 기록 시작
5. 몇 가지 앱/창 전환
6. 빠른 메모 저장
7. OCR 상태 확인
8. 회의 전사 source 선택 후 transcript 저장 확인
9. Timeline 확인
10. Report 생성
11. AI Key 없이 fallback report 생성 확인
12. AI Key가 있으면 AI report 생성 확인
13. Menu bar 열기
14. Floating widget 열고 닫기
15. Launch at Login toggle 확인

자세한 기능별 기준은 [QA Checklist](QA_CHECKLIST.md)를 참고하세요.

## 문제 해결

### 앱이 열리지 않음

- DMG 내부 앱을 실행하지 않았는지 확인합니다.
- `/Applications/MwohamMac.app`으로 복사했는지 확인합니다.
- Finder 우클릭 > 열기를 시도합니다.
- 시스템 설정 > 개인정보 보호 및 보안 > Open Anyway를 확인합니다.
- 최후 수단으로 quarantine 제거 명령을 사용합니다.

### backend 연결 실패

- 앱 설정의 backend 상태와 최근 로그를 확인합니다.
- 포트 `8765`가 다른 프로세스에 사용 중인지 확인합니다.

```bash
lsof -ti :8765
```

개발/QA 환경에서만 강제 종료가 필요하면:

```bash
lsof -ti :8765 | xargs kill -9
```

### 권한 팝업이 다시 안 뜸

- 이미 거부한 권한은 macOS가 팝업을 다시 띄우지 않을 수 있습니다.
- 시스템 설정에서 직접 허용하거나 `tccutil reset All com.ing2720.MwohamMac` 후 다시 실행합니다.
- 화면 기록/접근성은 허용 후 앱 재시작이 필요할 수 있습니다.

### STT 사용 불가

- 설정 > Local Whisper 상태를 확인합니다.
- `whisper-cli` 또는 `large-v3-turbo` 모델 없음으로 표시되면 최신 DMG를 다시 설치합니다.
- `whisper-cli` 실행 권한 없음으로 표시되면 배포 파일이 손상됐을 수 있습니다.

### Report가 fallback으로 생성됨

- AI API Key가 입력되지 않았을 수 있습니다.
- quota를 초과했을 수 있습니다.
- 선택한 모델을 계정에서 사용할 수 없을 수 있습니다.
- 네트워크/API timeout이 발생했을 수 있습니다.

## 테스터가 전달하면 좋은 정보

문제가 재현되면 아래 정보를 전달합니다.

```bash
uname -m
sw_vers
spctl --assess --verbose /Applications/MwohamMac.app
codesign --verify --deep --strict --verbose=2 /Applications/MwohamMac.app
curl http://127.0.0.1:8765/health
```

앱 설정 화면의 backend 상태, Local Whisper 상태, 권한 상태도 함께 알려주면 원인 파악이 빠릅니다.

## 현재 한계

- 내부 QA/포트폴리오 시연용 빌드입니다.
- Developer ID signing/notarization이 적용되지 않았습니다.
- Gatekeeper 경고가 표시될 수 있습니다.
- 자동 업데이트는 없습니다.
- 권한 허용 후 앱 재시작이 필요할 수 있습니다.
