# Mwoham macOS Client

MwohamMac은 로컬 backend와 연결되는 macOS SwiftUI 앱입니다. 일반 창, 메뉴바, 플로팅 위젯에서 기록 상태를 확인하고, 빠른 메모, OCR, 회의 전사, 자동 Dev Tracking 상태를 표시합니다.

backend 기본 주소는 `http://127.0.0.1:8765`입니다. backend가 실행 중이지 않으면 앱은 연결 실패 안내와 대시보드 열기/새로고침 동작을 제공합니다.

현재 macOS client는 Release packaging 직전 QA 대상입니다. Apple Development
signed 앱은 내부 개발/권한 QA용이고, Developer ID notarization과 DMG/ZIP
배포 산출물은 다음 packaging 단계에서 다룹니다.

## 주요 역할

- backend `/health`, `/status` 연결 상태 표시
- 기록 시작, 일시정지, 재개, 종료
- 빠른 메모 저장
- 활성 앱/창 메타데이터 추적
- OCR 텍스트 수집
- Apple Speech 기반 회의 전사
- 자동 Dev Tracking watcher process 실행과 상태 표시
- 메뉴바와 플로팅 위젯 상태 표시
- 플로팅 위젯 설정 저장/로드/reset
- AI Provider 설정과 API Key Keychain 저장
- Launch at Login 설정

## macOS 권한 안내

활성 앱 이름은 일반적으로 별도 권한 없이 확인할 수 있습니다. 활성 창 제목은 macOS 개인정보 보호 설정에 따라 비어 있을 수 있습니다.

창 제목이 비어 있으면 시스템 설정 > 개인정보 보호 및 보안에서 MwohamMac 앱에 손쉬운 사용 권한을 허용해 주세요. macOS 버전이나 대상 앱에 따라 화면 기록 권한이 필요할 수도 있습니다.

접근성 권한은 앱이 자동으로 승인할 수 없습니다. 개발 빌드는 Xcode DerivedData
경로에서 직접 실행하지 말고 다음 고정 bundle을 사용합니다.

```bash
# signed Debug
./scripts/build_macos_app.sh --open

# signed Release
./scripts/build_macos_app.sh --release --open
```

기본 실행 경로는 `~/Applications/MwohamMac.app`, bundle identifier는
`com.ing2720.MwohamMac`입니다. 스크립트는 Apple Development 인증서와 Team
ID를 요구하고 ad-hoc 서명을 거부합니다.

개인 Team ID는 repo에 저장하지 않고
`~/.config/mwoham/macos-signing.env`에 설정합니다.

```bash
MWOHAM_DEVELOPMENT_TEAM=YOUR_TEAM_ID
```

Team ID는 인증서 Common Name의 괄호 값이 아니라 certificate subject의 `OU`와
일치해야 합니다. `MWOHAM_CODE_SIGN_IDENTITY`는 인증서가 여러 개인 경우에만
`security find-identity -v -p codesigning`의 전체 이름으로 지정합니다.

서명 인증서는 Xcode > Settings > Accounts에서 Apple ID를 등록하고
`Manage Certificates...`에서 Apple Development 인증서를 생성합니다.

다른 Mac이나 CI에서 UI만 확인하려면 다음 명시적 unsigned 모드를 사용합니다.

```bash
./scripts/build_macos_app.sh --unsigned
./scripts/build_macos_app.sh --unsigned --open
./scripts/build_macos_app.sh --unsigned --release
```

unsigned 앱은 접근성, 화면 기록, 마이크 등 TCC 권한이 빌드마다 유지되는 것을
보장하지 않습니다. 권한 QA에는 signed 고정 경로 앱만 사용합니다.

## 앱 빌드 기준

- 기본 configuration: `Debug`
- 설치 앱 최종 확인: signed `Release`
- 표시 이름: `MwohamMac`
- bundle identifier: `com.ing2720.MwohamMac`
- version/build: `1.0 (1)`
- 기본 설치 경로: `~/Applications/MwohamMac.app`
- 아이콘: `Assets.xcassets/AppIcon.appiconset`의 개발용 placeholder

스크립트는 기존 앱 프로세스를 종료하고 bundle을 교체한 뒤, signed 모드에서
strict codesign과 TeamIdentifier를 확인하고 LaunchServices에 다시 등록합니다.
`--destination` 또는 `APP_PATH`를 명시하지 않으면 `/Applications`를 사용하지
않습니다. signed 실패가 unsigned로 자동 전환되는 동작은 없습니다.

## Floating Widget

플로팅 위젯은 메뉴바 presentation 값을 공유해 recording, 현재 앱/창, OCR,
Dev Tracking, 회의모드 상태를 표시합니다. 위젯 창 크기에 따라 표시 항목과
빠른 액션을 줄이는 responsive layout을 사용합니다.

지원 설정:

- 투명도: 60%~100%
- 색상 preset: 시스템, 초록, 파랑, 보라, 주황, 회색
- 표시 항목: 현재 앱, 현재 창, OCR 상태, Dev Tracking 상태, 기록 시간
- 빠른 액션: 메인 창 열기, 대시보드 열기, Dev Tracking 시작/중지, 회의모드 시작/중지
- 기본값 초기화

설정은 `UserDefaults`의 `floatingWidgetSettings`에 저장됩니다. 위젯 크기/위치
저장, custom color picker, recording 자동 시작 정책 변경은 현재 범위에
포함하지 않습니다.

## AI 리포트 설정

설정 화면의 `AI 리포트 설정`에서 provider를 선택하고 API Key를 입력할 수
있습니다.

- Provider: Gemini, OpenAI
- API Key 저장 위치: macOS Keychain
- Provider/model 저장 위치: UserDefaults
- 모델 선택: 연결 테스트 또는 모델 불러오기 후 dropdown에서 선택
- key 삭제: 현재 선택한 provider의 Keychain 항목만 삭제
- key 없음 또는 API 실패: backend가 로컬 fallback 리포트를 생성

API Key 전체 값은 저장 후 다시 표시하지 않고 `••••1234` 형태의 요약만
표시합니다. 모델명은 직접 입력하지 않고 provider API에서 조회된 compatible
model 목록에서 선택합니다.

앱이 backend를 새로 시작할 때 선택한 provider/model/key를 process environment에
주입합니다. 이미 외부에서 실행 중인 backend에는 자동으로 주입되지 않으므로,
설정 변경 후 앱이 시작한 backend를 재시작하거나 외부 backend를 다시 실행해야
합니다.

## Launch at Login

설정 화면의 `자동 실행` 카드에서 `로그인 시 자동 실행`을 켜고 끌 수 있습니다.
이 기능은 macOS 로그인 시 `MwohamMac` 앱을 실행하는 것만 담당합니다.
로그인 자동 실행 상태에서도 기록은 자동으로 시작되지 않으며, 사용자가 직접
`기록 시작`을 눌러야 recording session이 시작됩니다.

상태가 맞지 않으면 설정 화면의 `상태 새로고침`을 눌러 macOS 로그인 항목 등록
상태를 다시 확인합니다. 권한/TCC 테스트와 마찬가지로 signed 앱
`~/Applications/MwohamMac.app` 기준으로 확인하는 것을 권장합니다.

현재 단계의 활성 창 추적은 화면 이미지나 마이크 입력을 저장하지 않습니다. 앱 이름과 창 제목 메타데이터를 사용해 `app_name + window_title` 기준 작업 구간을 만들고, 같은 앱/창이 유지되는 동안 duration을 누적합니다.

권한이 없어도 앱은 화면 이미지를 캡처하지 않으며, 활성 창 제목은 빈 값으로 저장될 수 있습니다.

## OCR 권한 안내

OCR 수집은 macOS 화면 기록 권한이 필요합니다. MwohamMac 앱에 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록 권한을 허용해 주세요.

OCR은 캡처 이미지를 파일로 저장하거나 backend로 전송하지 않습니다. 화면 이미지는 메모리에서 Apple Vision OCR 처리에만 사용하며, backend에는 추출된 텍스트와 중복 방지용 해시만 저장합니다.

## Dev Tracking

macOS 앱은 개발 도구가 활성화되면 backend watcher process를 자동 실행합니다. 시작/종료 버튼은 없습니다.

개발 도구 판단 대상:

- PyCharm
- Visual Studio Code
- Code
- Terminal
- iTerm
- iTerm2
- Cursor

자동 실행 정책:

- 개발 도구 활성화 시 watcher가 꺼져 있으면 자동 시작합니다.
- watcher가 이미 실행 중이면 중복 실행하지 않습니다.
- 비개발 앱으로 이동하면 grace period 후 watcher를 종료합니다.
- 다시 개발 도구로 돌아오면 종료 예약을 취소합니다.
- 앱 종료 시 child process를 종료합니다.
- watcher stdout/stderr를 읽어 앱 상태에 반영합니다.

실행 방식:

```bash
cd backend
uv run python scripts/watch_dev_context.py --repo-path <repo> --interval 60 --session-current
```

앱은 `PATH`, `UV_CACHE_DIR`, `PYTHONUNBUFFERED`를 보강해 watcher stdout/stderr가 막히지 않게 처리합니다.

## Dev Tracking repo path 설정

앱 설정 영역에서 `Dev Tracking 추적 repo 경로`를 1개 입력할 수 있습니다.

- 저장 위치: `UserDefaults`의 `devTrackingRepoPath`
- 비어 있으면 현재 mwoham repo fallback 사용
- 여러 repo 지원 없음
- repo 자동 추정 없음
- 수동 시작/종료 버튼 없음

유효성 검사는 다음 순서로 수행합니다.

1. path 존재 여부
2. 디렉터리 여부
3. `git -C <repoPath> rev-parse --show-toplevel` 성공 여부

Git repo가 아니거나 path가 없으면 앱은 종료되지 않고 `Dev Tracking 오류: ...` 상태를 표시합니다.

Dev Tracking 상태는 메인 상태 영역, 메뉴바, 플로팅 위젯에 표시됩니다.

## 회의 전사 구조

macOS 앱은 Apple Speech와 local Whisper 기반 회의 전사를 지원합니다. 전사 입력 source는 세 가지입니다.

- `마이크`: `AppleSpeechTranscriptionProvider`가 마이크 입력을 전사하고, transcript source는 `apple_speech_microphone`으로 저장합니다.
- `시스템 오디오`: ScreenCaptureKit display-wide capture로 시스템 오디오를 받고, `SystemAudioDisplayCaptureTarget`, `SystemAudioPCMBufferConverter`, `SystemAudioLevelMeter`, `SystemAudioSpeechTranscriptionProvider`를 통해 전사합니다. transcript source는 `apple_speech_system_audio`로 저장합니다.
- `회의 전체`: `FullMeetingSpeechTranscriptionProvider`가 마이크와 시스템 오디오 입력을 하나의 Apple Speech recognitionTask와 임시 16 kHz WAV에 전달합니다. 종료 시 설정된 `whisper-cli`가 성공하면 `local_whisper_full_meeting`, 미설정 또는 실패하면 `apple_speech_full_meeting` source로 저장합니다.

회의 전체 모드는 Apple Speech recognitionTask 두 개를 동시에 실행하지 않습니다. Apple Speech는 실시간 fallback이며, local Whisper는 회의 종료 시 일괄 처리합니다. UI의 `STT engine`에서 현재 우선 engine과 fallback 결과를 확인할 수 있습니다.

Whisper binary/model 경로는 회의 전체 UI에서 설정하고 `UserDefaults`에 저장합니다. 모델 파일은 앱이나 repo에 포함하지 않습니다. 화자 분리와 마이크/시스템 오디오 믹싱 고도화는 현재 범위에 포함하지 않습니다.

## 회의 전사 권한 안내

전사 source별 필요한 권한은 다음과 같습니다.

- 마이크 전사: 음성 인식, 마이크
- 시스템 오디오 전사: 음성 인식, 화면 기록
- 회의 전체 전사: 음성 인식, 마이크, 화면 기록

MwohamMac 앱에 시스템 설정 > 개인정보 보호 및 보안에서 필요한 권한을 허용해 주세요.

권한을 거부한 뒤 다시 회의 전사 시작을 누르면 앱에서 권한 안내 팝업을 표시하고, 음성 인식 또는 마이크 설정 화면을 열 수 있습니다.

권한이 거부되어도 앱은 종료되지 않고 한국어 안내 메시지를 표시합니다.

## 회의 전사 저장 정책

회의 전사는 원본 오디오 파일을 영구 저장하지 않고, raw audio buffer를 DB에 저장하지 않으며, backend로 audio data를 전송하지 않습니다.

회의 전체 Local Whisper 처리를 위한 WAV는 운영체제 임시 디렉터리에만 만들고 처리 후 삭제합니다. backend에는 Apple Speech 또는 Local Whisper가 반환한 transcript text만 기존 `/meeting-transcripts` API로 저장합니다.

DB schema, migration, API endpoint는 변경하지 않았고, 기존 source validation에 `local_whisper_full_meeting`만 추가했습니다.

## 시스템 오디오 캡처/전사

시스템 오디오 캡처는 ScreenCaptureKit 기반 display-wide capture로 검증했습니다. 현재 개발용 캡처 probe UI는 제거되었고, 시스템 오디오 단독 전사와 회의 전체 전사 흐름에 필요한 구조만 남아 있습니다.

시스템 오디오 전사도 원본 오디오를 파일로 저장하지 않고 backend로 전송하지 않습니다. 자세한 내용은 [시스템 오디오 캡처/전사](../docs/SYSTEM_AUDIO_CAPTURE_SPIKE.md)를 참고하세요.

## Privacy / Safety

현재 macOS 앱 구현은 다음 원칙을 유지합니다.

- 원본 화면 이미지 저장 없음
- OCR 캡처 이미지를 backend로 전송하지 않음
- 원본 오디오 영구 저장 없음
- Local Whisper용 임시 WAV는 처리 후 삭제
- raw audio buffer 저장 없음
- backend로 audio data 전송 없음
- transcript text만 `/meeting-transcripts` API로 저장
- Dev Tracking은 Git diff 본문이나 파일 내용을 저장하지 않음
- debug audio WAV는 사용자가 명시적으로 QA/debug 보관을 켠 경우에만
  `~/Library/Application Support/Mwoham/debug_audio/`에 복사
- AI Provider API Key는 UserDefaults에 저장하지 않고 Keychain에만 저장
