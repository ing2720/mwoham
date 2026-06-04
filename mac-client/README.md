# Mwoham macOS Client

## macOS 권한 안내

활성 앱 이름은 일반적으로 별도 권한 없이 확인할 수 있습니다. 활성 창 제목은 macOS 개인정보 보호 설정에 따라 비어 있을 수 있습니다.

창 제목이 비어 있으면 시스템 설정 > 개인정보 보호 및 보안에서 MwohamMac 앱에 손쉬운 사용 권한을 허용해 주세요. macOS 버전이나 대상 앱에 따라 화면 기록 권한이 필요할 수도 있습니다.

현재 단계의 활성 창 추적은 화면 이미지나 마이크 입력을 저장하지 않습니다. 앱 이름과 창 제목 메타데이터를 사용해 `app_name + window_title` 기준 작업 구간을 만들고, 같은 앱/창이 유지되는 동안 duration을 누적합니다.

권한이 없어도 앱은 화면 이미지를 캡처하지 않으며, 활성 창 제목은 빈 값으로 저장될 수 있습니다.

## OCR 권한 안내

OCR 수집은 macOS 화면 기록 권한이 필요합니다. MwohamMac 앱에 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록 권한을 허용해 주세요.

OCR은 캡처 이미지를 파일로 저장하거나 backend로 전송하지 않습니다. 화면 이미지는 메모리에서 Apple Vision OCR 처리에만 사용하며, backend에는 추출된 텍스트와 중복 방지용 해시만 저장합니다.

## 회의 전사 구조

macOS 앱은 Apple Speech 기반 회의 전사를 지원합니다. 전사 입력 source는 세 가지입니다.

- `마이크`: `AppleSpeechTranscriptionProvider`가 마이크 입력을 전사하고, transcript source는 `apple_speech_microphone`으로 저장합니다.
- `시스템 오디오`: ScreenCaptureKit display-wide capture로 시스템 오디오를 받고, `SystemAudioDisplayCaptureTarget`, `SystemAudioPCMBufferConverter`, `SystemAudioLevelMeter`, `SystemAudioSpeechTranscriptionProvider`를 통해 전사합니다. transcript source는 `apple_speech_system_audio`로 저장합니다.
- `회의 전체`: `FullMeetingSpeechTranscriptionProvider`가 마이크와 시스템 오디오 입력을 하나의 Apple Speech recognitionTask에 넣어 전사합니다. transcript source는 `apple_speech_full_meeting`으로 저장합니다.

회의 전체 모드는 Apple Speech recognitionTask 두 개를 동시에 실행하지 않습니다. 단독 마이크 전사와 단독 시스템 오디오 전사는 각각 정상 동작했지만, 두 recognitionTask를 동시에 실행하면 한쪽이 실패하는 문제가 있어 single recognitionTask 방식으로 정리했습니다.

화자 분리, 마이크와 시스템 오디오 믹싱 고도화, Whisper/OpenAI STT는 현재 범위에 포함하지 않습니다.

## 회의 전사 권한 안내

전사 source별 필요한 권한은 다음과 같습니다.

- 마이크 전사: 음성 인식, 마이크
- 시스템 오디오 전사: 음성 인식, 화면 기록
- 회의 전체 전사: 음성 인식, 마이크, 화면 기록

MwohamMac 앱에 시스템 설정 > 개인정보 보호 및 보안에서 필요한 권한을 허용해 주세요.

권한을 거부한 뒤 다시 회의 전사 시작을 누르면 앱에서 권한 안내 팝업을 표시하고, 음성 인식 또는 마이크 설정 화면을 열 수 있습니다.

권한이 거부되어도 앱은 종료되지 않고 한국어 안내 메시지를 표시합니다.

## 회의 전사 저장 정책

회의 전사는 원본 오디오 파일을 저장하지 않고, raw audio buffer를 DB에 저장하지 않으며, backend로 audio data를 전송하지 않습니다.

backend에는 Apple Speech가 반환한 transcript text만 기존 `/meeting-transcripts` API로 저장합니다. 입력 경로는 transcript `source` 값으로 구분합니다.

DB schema, migration, API endpoint는 시스템 오디오 전사 연결 과정에서 변경하지 않았습니다.

## 시스템 오디오 캡처 Spike

시스템 오디오 캡처는 ScreenCaptureKit 기반 display-wide capture로 검증했습니다. 현재 개발용 캡처 probe UI는 제거되었고, 시스템 오디오 단독 전사와 회의 전체 전사 흐름에 필요한 구조만 남아 있습니다.

시스템 오디오 전사도 원본 오디오를 파일로 저장하지 않고 backend로 전송하지 않습니다. 자세한 내용은 [시스템 오디오 캡처 Spike](../docs/SYSTEM_AUDIO_CAPTURE_SPIKE.md)를 참고하세요.
