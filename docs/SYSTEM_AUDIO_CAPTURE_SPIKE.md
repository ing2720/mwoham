# 시스템 오디오 캡처/전사

이 문서는 v0.5 기준 시스템 오디오 캡처와 Apple Speech 연결 구조를 정리합니다.

초기에는 기술 검증 spike로 시작했지만, 현재 구현에서는 마이크, 시스템 오디오, 회의 전체 전사 source가 macOS 앱의 회의 전사 흐름에 연결되어 있습니다. Whisper/OpenAI STT, 화자 분리, 고급 회의 요약은 포함하지 않습니다.

## 목표

- macOS 공식 API로 시스템 오디오 또는 앱/윈도우 오디오 캡처 가능성 확인
- 브라우저, ZEP, Meet, Zoom 등에서 재생되는 상대방 음성이 buffer로 들어오는지 확인
- 이어폰 사용 시에도 buffer가 들어오는지 확인
- ScreenCaptureKit audio buffer를 Apple Speech에 전달할 수 있는지 확인
- 마이크, 시스템 오디오, 회의 전체 입력 source 분리
- 원본 오디오 파일 저장 금지
- raw audio buffer 저장 금지
- backend로 audio data 전송 금지
- transcript text만 backend에 저장
- 기존 Apple Speech 마이크 전사 흐름 유지

## 구현 범위

- `SystemAudioDisplayCaptureTarget`로 main display 기준 display-wide capture target 구성
- ScreenCaptureKit `SCStream`의 audio output으로 `CMSampleBuffer` 수신
- `SystemAudioLevelMeter`로 RMS/peak dB level 계산
- `SystemAudioPCMBufferConverter`로 시스템 오디오 buffer를 Apple Speech에 전달 가능한 PCM buffer로 변환
- `SystemAudioSpeechTranscriptionProvider`로 시스템 오디오 단독 전사 연결
- `FullMeetingSpeechTranscriptionProvider`로 마이크와 시스템 오디오를 하나의 Apple Speech recognitionTask에 연결
- 개발용 `SystemAudioCaptureProbe` UI는 검증 후 제거
- 오디오 파일 저장 없음
- raw audio buffer DB 저장 없음
- backend 전송 없음
- transcript text만 기존 `/meeting-transcripts` API로 저장

## 사용 API

- `ScreenCaptureKit`
  - `SCShareableContent`
  - `SCContentFilter`
  - `SCStreamConfiguration`
  - `SCStream`
  - `SCStreamOutput`
- `Speech`
  - `SFSpeechRecognizer`
  - `SFSpeechAudioBufferRecognitionRequest`
  - `SFSpeechRecognitionTask`
- `AVFoundation`
  - `AVAudioEngine`
  - `AVAudioPCMBuffer`
  - `AVAudioConverter`
- `CoreMedia`
  - `CMSampleBuffer`
  - `CMAudioFormatDescriptionGetStreamBasicDescription`
- `CoreGraphics`
  - `CGPreflightScreenCaptureAccess`
  - `CGRequestScreenCaptureAccess`

## 회의 전사 source

macOS 앱은 세 가지 전사 입력 source를 사용합니다.

- `마이크`: `AppleSpeechTranscriptionProvider`
  - 입력: 마이크
  - transcript source: `apple_speech_microphone`
- `시스템 오디오`: `SystemAudioSpeechTranscriptionProvider`
  - 입력: ScreenCaptureKit display-wide system audio
  - 주요 타입: `SystemAudioDisplayCaptureTarget`, `SystemAudioPCMBufferConverter`, `SystemAudioLevelMeter`
  - transcript source: `apple_speech_system_audio`
- `회의 전체`: `FullMeetingSpeechTranscriptionProvider`
  - 입력: 마이크 + 시스템 오디오
  - 처리 방식: 하나의 Apple Speech recognitionTask에 두 입력을 append
  - transcript source: `apple_speech_full_meeting`

## 필요한 권한

- 마이크 전사: 음성 인식, 마이크
- 시스템 오디오 전사: 음성 인식, 화면 기록
- 회의 전체 전사: 음성 인식, 마이크, 화면 기록

권한을 허용한 뒤 앱 재실행이 필요할 수 있습니다. 권한이 거부되어도 앱은 종료되지 않고 안내 메시지를 표시합니다.

## 확인 방법

1. backend와 MwohamMac 앱을 실행합니다.
2. 회의 전사 입력 source에서 `시스템 오디오`를 선택합니다.
3. 브라우저, ZEP, Meet, Zoom 등에서 소리를 재생합니다.
4. 시스템 오디오 transcript가 저장되는지 확인합니다.
5. 이어폰 사용 상태에서도 같은 테스트를 반복합니다.
6. `회의 전체` source를 선택하고 마이크 발화와 시스템 오디오 재생을 함께 확인합니다.

## 성공 기준

- 시스템 오디오 buffer가 수신되고 RMS/peak level이 소리 재생에 따라 변합니다.
- 시스템 오디오 단독 전사에서 transcript text가 생성됩니다.
- 마이크 단독 전사와 시스템 오디오 단독 전사가 각각 정상 동작합니다.
- 회의 전체 전사는 Apple Speech recognitionTask 하나로 동작합니다.
- transcript text만 `/meeting-transcripts` API로 저장됩니다.
- 원본 오디오 파일, raw audio buffer, backend audio data 전송이 없습니다.
- 기존 마이크 기반 회의 전사 기능이 깨지지 않습니다.

## 주요 결정 사항

Apple Speech recognitionTask 두 개를 동시에 실행하는 방식은 사용하지 않습니다.

마이크 단독 전사와 시스템 오디오 단독 전사는 각각 정상 동작했지만, 회의 전체 모드에서 두 recognitionTask를 동시에 실행하면 한쪽이 `No speech detected` 계열 오류로 실패하는 패턴이 확인되었습니다.

따라서 회의 전체 전사는 마이크와 시스템 오디오를 별도 recognitionTask로 분리하지 않고, `FullMeetingSpeechTranscriptionProvider`에서 하나의 Apple Speech recognitionTask에 두 입력을 append하는 방식으로 정리했습니다.

이번 범위에서는 화자 분리, Whisper/OpenAI STT, 고급 오디오 믹싱을 구현하지 않습니다.

## 저장 정책

- 원본 오디오 파일 저장 없음
- raw audio buffer DB 저장 없음
- backend로 audio data 전송 없음
- Apple Speech가 반환한 transcript text만 저장
- transcript source로 입력 경로 구분
  - `apple_speech_microphone`
  - `apple_speech_system_audio`
  - `apple_speech_full_meeting`
- DB schema, migration, API endpoint 변경 없음

## 현재 제한사항

- 전사 품질은 후속 개선 대상입니다.
- 장시간 실제 회의 안정성은 추가 확인이 필요합니다.
- 반복 transcript, 잡음 transcript 필터링이 필요할 수 있습니다.
- 리포트 회의 섹션 반영 품질은 후속 확인이 필요합니다.
- 화자 구분은 없습니다.
- 특정 앱 단위 audio filtering은 구현하지 않았습니다.

## Apple Speech 연결 결과

ScreenCaptureKit audio output은 `CMSampleBuffer` 형태로 들어옵니다. 이 buffer를 `SystemAudioPCMBufferConverter`로 mono Float32 PCM buffer로 변환한 뒤 `SFSpeechAudioBufferRecognitionRequest`에 append합니다.

시스템 오디오 단독 전사는 별도 Apple Speech recognitionTask를 사용합니다. 회의 전체 전사는 마이크와 시스템 오디오를 하나의 Apple Speech recognitionTask에 넣습니다.

이 방식은 Apple Speech recognitionTask 동시 실행 충돌을 피하기 위한 현재 기준 구현입니다.

## 다음 구현 방향

1. fullMeeting transcript 품질 정책 조정
2. 짧거나 의미 없는 transcript 필터링
3. 리포트 회의 섹션 품질 개선
4. 실제 회의 장시간 테스트
5. 필요 시 다른 STT 엔진 검토
6. provider가 더 늘어나면 Apple Speech lifecycle helper 검토
