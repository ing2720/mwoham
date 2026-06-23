# Tester Install Guide

이 문서는 Xcode 없이 Mwoham을 설치해 보는 내부 QA/포트폴리오 시연용 안내입니다. 현재 배포물은 공개 배포용 앱이 아니며 Developer ID signing/notarization이 적용되지 않았습니다.

## 테스트 대상

- 최신 DMG: `dist/Mwoham-1.1.0.dmg` 또는 최신 `dist/Mwoham-*.dmg`
- 앱: `MwohamMac.app`
- Bundle ID: `com.ing2720.MwohamMac`
- backend: 앱이 로컬 `http://127.0.0.1:8765`에서 사용
- 설치 컴포넌트 위치: `~/Library/Application Support/Mwoham`
- 기본 DMG: lightweight. backend/STT CLI/STT model은 첫 실행 후 별도 설치
- STT: Application Support에 설치된 Local Whisper 우선 사용
- AI Report: Gemini/OpenAI API Key를 설정한 경우 provider 사용, 없거나 실패하면 fallback report

## 설치

1. 개발자가 전달한 최신 `Mwoham-*.dmg`를 엽니다.
2. DMG 안의 `MwohamMac.app`을 `Applications` 바로가기로 드래그합니다.
3. DMG 내부에서 바로 실행하지 말고 Applications 폴더로 복사된 앱을 실행합니다.
4. macOS가 확인되지 않은 앱 경고를 표시하면 내부 QA/포트폴리오 시연용 빌드인지 확인한 뒤 실행을 허용합니다.
5. 첫 실행 후 Settings > 필수 컴포넌트에서 `전체 설치`를 실행합니다.
6. 설치가 끝나면 backend가 migration/start/health check를 진행합니다.
7. 첫 실행 권한 온보딩에서 필요한 권한을 허용합니다.
8. 화면 기록/접근성 권한을 허용한 뒤에는 앱을 완전히 종료하고 다시 실행합니다.

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

일반 테스터는 별도 STT API Key가 필요 없습니다. Lightweight DMG에서는 STT CLI와 `ggml-large-v3-turbo.bin` 모델이 앱 실행 후 별도 다운로드됩니다. 모델 용량이 크므로 네트워크 상태에 따라 시간이 걸릴 수 있고, offline 상태에서는 설치가 실패합니다.

앱은 첫 실행 시 Application Support 아래에 설치된 STT runtime을 우선 확인합니다.

```text
~/Library/Application Support/Mwoham/stt/bin/whisper-cli
~/Library/Application Support/Mwoham/stt/models/ggml-large-v3-turbo.bin
~/Library/Application Support/Mwoham/stt/lib/*.dylib
```

DMG에 STT runtime이 포함된 full 배포판이면 앱 번들의 `Resources/STT` 또는 `Resources/stt`는 설치 원본으로 사용됩니다. Lightweight 배포판에서는 앱 번들에 STT resource가 없으며, 모델이 없으면 앱이 종료되지 않고 설정 화면의 Local Whisper 상태에 모델 미설치로 표시됩니다.

회의 전사 정책:

- 원본 오디오는 영구 저장하지 않습니다.
- Local Whisper 처리용 임시 파일은 처리 후 삭제합니다.
- backend에는 transcript text만 저장합니다.
- STT resource가 없거나 실행 권한이 없으면 설정 화면의 Local Whisper 상태 카드에 표시됩니다.

## 설치 컴포넌트와 복구

MwohamMac 앱 본체와 runtime component는 분리되어 있습니다. 앱 본체는 `/Applications/MwohamMac.app`에 있고, backend/STT/data/log/manifest는 사용자 계정의 Application Support 아래에 준비됩니다.

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

문제가 있을 때 확인할 파일:

- `component_manifest.json`: backend, STT CLI, STT model의 `missing/downloading/installed/failed/version_mismatch/invalid` 상태, sourceURL, sha256, lastError
- `logs/`: 앱이 시작한 backend/runtime 로그 위치
- `data/`: 로컬 DB/export 등 runtime data 위치

재설치는 Settings > 필수 컴포넌트에서 컴포넌트별 `재설치` 또는 `전체 설치`를 사용합니다. 실패 시 `lastError`를 확인하고 네트워크, checksum 설정, 디스크 공간을 확인합니다. 내부 QA에서 Application Support component를 완전히 초기화해야 할 때만 개발자 안내에 따라 `~/Library/Application Support/Mwoham` 하위 component를 삭제한 뒤 재실행합니다.

`컴포넌트 sha256이 설정되지 않아 설치를 중단했습니다. 릴리즈 asset manifest를 확인하세요.`가 표시되면 해당 배포판의 component asset sha가 앱 source catalog 또는 remote manifest에 연결되지 않은 상태입니다. 개발자에게 `dist/components/sha256sums.txt`와 GitHub Release asset 업로드 상태 확인을 요청합니다.

설치 위치:

```text
~/Library/Application Support/Mwoham/backend
~/Library/Application Support/Mwoham/stt/bin/whisper-cli
~/Library/Application Support/Mwoham/stt/lib
~/Library/Application Support/Mwoham/stt/models/ggml-large-v3-turbo.bin
~/Library/Application Support/Mwoham/component_manifest.json
```

Backend 실행에는 packaged `.venv`가 없으면 `uv`가 필요할 수 있습니다. 앱은 `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.cargo/bin`, Python framework 경로를 탐색합니다.

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
- 앱 설정의 backend 진단에서 `uv path`가 `uv missing`인지 확인합니다.
- `~/Library/Application Support/Mwoham/component_manifest.json`에서 backend status를 확인합니다.
- 포트 `8765`가 다른 프로세스에 사용 중인지 확인합니다.
- packaged `.venv`가 없는 내부 QA 빌드는 backend 실행에 `uv`가 필요할 수 있습니다. Finder로 실행한 앱은 터미널 shell PATH를 그대로 상속하지 않을 수 있어 앱이 common path resolver로 `uv`를 다시 찾습니다.

```bash
brew install uv
which uv
uv --version
```

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
- 마이크만 다시 요청하려면 개발/QA 환경에서 아래 명령을 사용할 수 있습니다.

```bash
tccutil reset Microphone com.ing2720.MwohamMac
```

- unsigned build, DerivedData 앱, DMG 내부 앱처럼 실행 경로/서명이 바뀌면 macOS가 같은 앱으로 인식하지 못할 수 있습니다. 권한 QA는 `/Users/a/Applications/MwohamMac.app` 또는 `/Applications/MwohamMac.app`처럼 고정된 앱 경로에서 확인합니다.

### STT 사용 불가

- 설정 > Local Whisper 상태를 확인합니다.
- `~/Library/Application Support/Mwoham/component_manifest.json`에서 STT CLI/model status를 확인합니다.
- `whisper-cli` 또는 `large-v3-turbo` 모델 없음으로 표시되면 최신 DMG를 다시 설치하거나 모델 포함 배포판을 사용합니다.
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
codesign -d --entitlements :- /Applications/MwohamMac.app 2>/dev/null | grep com.apple.security.device.audio-input
curl http://127.0.0.1:8765/health
```

앱 설정 화면의 backend 상태, Local Whisper 상태, 권한 상태도 함께 알려주면 원인 파악이 빠릅니다.

## 현재 한계

- 내부 QA/포트폴리오 시연용 빌드입니다.
- Developer ID signing/notarization이 적용되지 않았습니다.
- Gatekeeper 경고가 표시될 수 있습니다.
- 자동 업데이트는 없습니다.
- 권한 허용 후 앱 재시작이 필요할 수 있습니다.
- 현재 원격 추가 다운로드 UI는 없습니다.
- lite/full DMG 분리는 향후 개선 항목입니다.
