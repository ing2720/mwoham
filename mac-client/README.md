# Mwoham macOS Client

MwohamMac은 로컬 backend와 연결되는 macOS SwiftUI 앱입니다. 일반 창, 메뉴바, 플로팅 위젯에서 기록 상태를 확인하고, 빠른 메모, OCR, 회의 전사, 자동 Dev Tracking 상태를 표시합니다.

backend 기본 주소는 `http://127.0.0.1:8765`입니다. backend가 실행 중이지 않으면 앱은 연결 실패 안내와 대시보드 열기/새로고침 동작을 제공합니다.

## 주요 역할

- backend `/health`, `/status` 연결 상태 표시
- 기록 시작, 일시정지, 재개, 종료
- 빠른 메모 저장
- 활성 앱/창 메타데이터 추적
- OCR 텍스트 수집
- Apple Speech 기반 회의 전사
- 자동 Dev Tracking watcher process 실행과 상태 표시
- 메뉴바와 플로팅 위젯 상태 표시

## macOS 권한 안내

활성 앱 이름은 일반적으로 별도 권한 없이 확인할 수 있습니다. 활성 창 제목은 macOS 개인정보 보호 설정에 따라 비어 있을 수 있습니다.

창 제목이 비어 있으면 시스템 설정 > 개인정보 보호 및 보안에서 MwohamMac 앱에 손쉬운 사용 권한을 허용해 주세요. macOS 버전이나 대상 앱에 따라 화면 기록 권한이 필요할 수도 있습니다.

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
