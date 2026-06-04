# 시스템 오디오 캡처 Spike

이 문서는 v0.4.0 meeting transcription 이후 시스템 오디오 캡처 가능성을 확인하기 위한 기술 검증 기록입니다.

이번 spike는 제품 기능 완성이 아니라 가능성 확인입니다. Whisper/OpenAI STT, 화자 분리, 고급 회의 요약은 포함하지 않습니다.

## 목표

- macOS 공식 API로 시스템 오디오 또는 앱/윈도우 오디오 캡처 가능성 확인
- 브라우저, ZEP, Meet, Zoom 등에서 재생되는 상대방 음성이 buffer로 들어오는지 확인
- 이어폰 사용 시에도 buffer가 들어오는지 확인
- 원본 오디오 파일 저장 금지
- backend로 audio data 전송 금지
- 기존 Apple Speech 마이크 전사 흐름 유지

## 구현 범위

- `SystemAudioCaptureProbe` 추가
- ScreenCaptureKit `SCStream`의 audio output을 사용해 audio sample buffer 수신 여부만 확인
- 메인 창에 개발/검증용 `시스템 오디오 캡처 테스트` 섹션 추가
- 캡처 상태에 buffer count, sample count, format, RMS/peak level dB, timestamp 표시
- 오디오 파일 저장 없음
- raw audio buffer DB 저장 없음
- backend 전송 없음

## 사용 API

- `ScreenCaptureKit`
  - `SCShareableContent`
  - `SCContentFilter`
  - `SCStreamConfiguration`
  - `SCStream`
  - `SCStreamOutput`
- `CoreMedia`
  - `CMSampleBuffer`
  - `CMAudioFormatDescriptionGetStreamBasicDescription`
- `CoreGraphics`
  - `CGPreflightScreenCaptureAccess`
  - `CGRequestScreenCaptureAccess`

## 필요한 권한

ScreenCaptureKit audio capture는 화면 기록 권한 흐름과 함께 동작합니다.

- 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록
- 권한을 허용한 뒤 앱 재실행 필요 가능

현재 마이크 기반 Apple Speech 전사는 별도 권한을 사용합니다.

- 시스템 설정 > 개인정보 보호 및 보안 > 음성 인식
- 시스템 설정 > 개인정보 보호 및 보안 > 마이크

## 확인 방법

1. backend와 MwohamMac 앱을 실행합니다.
2. 메인 창에서 `시스템 오디오 캡처 테스트` 섹션을 찾습니다.
3. `테스트 시작`을 누릅니다.
4. 브라우저, ZEP, Meet, Zoom 등에서 소리를 재생합니다.
5. `캡처 상태`가 `buffer 수신됨`으로 바뀌는지 확인합니다.
6. 이어폰 사용 상태에서도 같은 테스트를 반복합니다.
7. 테스트가 끝나면 `테스트 종료`를 누릅니다.

## 성공 기준

- 상태가 `시스템 오디오 캡처 시작됨, buffer 대기 중`으로 표시됩니다.
- 소리 재생 중 상태가 `buffer 수신됨`으로 갱신됩니다.
- sample count, format, RMS/peak level dB 정보가 표시됩니다.
- 소리가 없으면 낮은 level이 표시되고, 브라우저/회의 앱 소리가 재생되면 level 값이 변해야 합니다.
- 앱이 종료되거나 기존 회의 전사 기능이 깨지지 않습니다.

## 현재 제한사항

- 이 spike는 audio buffer 수신 여부만 확인합니다.
- buffer를 Apple Speech에 연결하지 않습니다.
- transcript를 생성하거나 backend에 저장하지 않습니다.
- 특정 앱 단위 audio filtering은 아직 구현하지 않았습니다.
- 이어폰 사용 시 결과는 실제 환경에서 수동 확인이 필요합니다.

## Apple Speech 연결 가능성

현재 Apple Speech 마이크 전사는 `AVAudioEngine.inputNode`에서 받은 buffer를 `SFSpeechAudioBufferRecognitionRequest`에 append합니다.

ScreenCaptureKit audio output도 `CMSampleBuffer` 형태로 buffer를 받을 수 있으므로, 다음 단계에서는 이 buffer를 `AVAudioPCMBuffer`로 변환해 `SFSpeechAudioBufferRecognitionRequest`에 append할 수 있는지 검증해야 합니다.

다만 현재 spike에서는 변환/전사까지 구현하지 않습니다. 다음 단계에서 source 개념을 분리하는 것이 안전합니다.

- `microphone`
- `system_audio`
- `mixed`

## 다음 구현 방향

1. 수동 QA로 시스템 오디오 buffer 수신 여부 확인
2. 이어폰/스피커/브라우저/회의 앱별 결과 기록
3. `SpeechTranscriptionProvider`에 audio source 개념 도입 여부 결정
4. ScreenCaptureKit audio buffer를 Apple Speech request에 연결하는 별도 spike 진행
5. Apple Speech 연결 품질이 낮으면 외부 STT는 별도 단계에서 검토
