# Local Whisper STT와 Meeting 연동

## 목적

이 문서는 다음 두 흐름을 설명합니다.

- MwohamMac 회의 전체 전사 종료 시 Local Whisper를 우선 사용하는 실제 meeting 흐름
- 동일한 짧은 한국어 WAV를 Apple Speech와 local `whisper.cpp`에 전달하는 비교 POC

현재 v0.1.x 내부 QA DMG는 `MwohamMac.app` 안에 `whisper-cli`,
`ggml-large-v3-turbo.bin`, 필요한 dylib를 포함합니다. 일반 테스터는 별도 STT API
key, Homebrew 설치, 모델 다운로드 없이 Local Whisper를 사용할 수 있습니다.

마이크와 시스템 오디오 단독 전사는 Apple Speech를 사용합니다. 회의 전체 전사는
Apple Speech를 실시간 fallback으로 계속 실행하고, 종료 시 Local Whisper가 정상
처리되면 Whisper transcript를 최종 저장합니다.

## Release DMG runtime 정책

DMG의 앱 번들에는 다음 resource가 포함되어야 합니다.

```text
MwohamMac.app/Contents/Resources/STT/whisper-cli
MwohamMac.app/Contents/Resources/STT/models/ggml-large-v3-turbo.bin
MwohamMac.app/Contents/Resources/STT/lib/*.dylib
```

runtime 탐색 순서:

1. bundled resource
2. 사용자 설정 override
3. Application Support fallback
4. 개발환경 fallback

모델 파일, `whisper-cli`, dylib 원본은 repo에 커밋하지 않습니다.

## MwohamMac Meeting 연동

앱의 `전사 입력`에서 `회의 전체`를 선택하면 Local Whisper 상태가 표시됩니다.

1. Release DMG에서는 bundled `whisper-cli`와 bundled model을 자동 탐색합니다.
2. 개발/QA override가 필요하면 설정에서 runtime/model 경로를 지정합니다.
3. 회의 전사를 시작합니다.
4. 회의 중에는 Apple Speech가 실시간 transcript를 생성하지만 backend에는 아직
   최종 저장하지 않습니다.
5. Local Whisper용 녹음은 microphone과 system audio를 별도 queue와 별도 임시
   CAF로 기록합니다. 두 source 모두 Apple Speech silence filtering 전에 기록하며
   raw audio를 서로 섞지 않습니다.
6. `회의 전사 종료`를 누르면 source별 임시 CAF를 각각 16 kHz mono signed
   16-bit PCM WAV로 변환합니다. 각 WAV는 15초 단위 chunk로 나누고 source와
   chunk별로 local Whisper를 독립 실행합니다.
7. 각 chunk에는 source, start time, end time metadata를 붙입니다. hallucination
   guard를 통과한 chunk transcript만 segment로 유지하고, microphone/system audio
   segment를 start time 기준으로 정렬해 병합합니다.

   ```text
   [00:01 system_audio] 상대방 말
   [00:03 microphone] 내 말
   [00:06 system_audio] 상대방 말
   [00:08 microphone] 내 말
   ```

   microphone 또는 system audio 한쪽만 성공해도 같은 timestamp/source label
   형식으로 최종 transcript를 만듭니다.
8. 부분 성공 또는 전체 성공 결과는 `local_whisper_full_meeting` source로 기존
   `/meeting-transcripts` API에 저장합니다.
9. source 하나가 실패하거나 모든 chunk가 reject되어도 다른 source의 유효한
   Whisper transcript는 저장합니다. 두 source 모두 유효하지 않거나 Whisper
   설정/실행 자체를 사용할 수 없을 때만 세션 중 확보한 Apple Speech 결과를
   `apple_speech_full_meeting` source로 저장합니다.

### Hallucination guard

각 15초 chunk 결과는 다음 조건으로 판정합니다. 해당하는 chunk는 최종 transcript에서
제외합니다. 다만 자막/광고/크레딧성 hallucination 문장이 chunk 앞/뒤에 독립적으로
붙은 경우에는 해당 문장만 제거하고 남은 회의 문장을 유지합니다.

- 빈 문자열, 점과 공백 위주, 구두점 비율이 과도한 결과
- `자막 제공`, `광고를 포함하고 있습니다`, `한글자막 by`, `자막 by`,
  `번역 by`, `구독 좋아요`, `시청해주셔서 감사합니다`, `subtitles by`,
  `translated by` 같은 자막/광고/크레딧성 hallucination이 chunk 전체를
  지배하는 결과. reject reason은 `subtitle_ad_hallucination`입니다.
- 같은 문장 또는 token sequence가 3회 이상 반복되고 chunk 결과의 절반 이상을
  차지하는 결과
- 같은 token이 과도하게 반복되거나 unique token 비율이 지나치게 낮은 결과
- 같은 한국어 음절/문자열이 3회 이상 반복되거나 unique character 비율이
  지나치게 낮은 결과
- 같은 정규화 transcript가 3개 이상 chunk에서 반복되는 결과
- Whisper process timeout, 빈 output, output 누락 또는 process 실패

한 source에서 일부 chunk만 reject되면 accepted chunk만 시간순으로 유지합니다.
두 source의 모든 chunk가 reject되면 Local Whisper transcript를 만들지 않고
Apple Speech fallback을 사용합니다.

앱은 `whisper-cli --help`를 실행해 현재 binary가 지원하는 옵션만 추가합니다.
`-l ko`는 항상 전달하며, 현재 Homebrew `whisper-cli`에서 확인된 경우 다음 옵션을
사용합니다.

```text
--no-fallback
--temperature 0
--temperature-inc 0
--no-speech-thold 0.50
--beam-size 5
--suppress-nst
```

지원하지 않는 옵션은 전달하지 않습니다. 별도 VAD model이 필요한 옵션은 이
단계에서 자동 활성화하지 않습니다.

UI의 `STT engine` 행에는 `Local Whisper`, `Apple Speech (fallback)` 또는 현재
설정 상태가 표시됩니다. `Whisper metadata`에는 다음 값이 표시됩니다.

- `combined full meeting`: 최종 포함 source, temporal merge 적용 여부, source별
  accepted count, Apple Speech fallback 여부
- `microphone Whisper`: 포함/제외 상태, WAV duration/size, 처리 시간, 문자 수,
  chunk 총수, accepted/rejected 수, reject reason 요약
- `system_audio Whisper`: 포함/제외 상태, WAV duration/size, 처리 시간, 문자 수,
  chunk 총수, accepted/rejected 수, reject reason 요약
- `debug_export`: source별로 명시적으로 보관한 debug WAV 경로 또는 `off`

경로와 debug 옵션 변경은 다음 회의 시작부터 적용됩니다.

## 범위와 데이터 정책

- 개발용 입력 오디오와 외부 Whisper 모델은 저장소 밖 경로에 있어야 합니다.
- 스크립트는 입력 WAV를 macOS 임시 디렉터리에서 16 kHz mono PCM WAV로 변환합니다.
- Apple Speech helper app, 변환 WAV, Whisper text output은 실행별 임시 디렉터리에만
  만들고 정상 종료와 오류 종료 모두에서 삭제합니다.
- transcript와 처리 시간은 터미널에만 출력하며 backend나 DB에 저장하지 않습니다.
- 원본 오디오는 수정하거나 복사해 저장소에 남기지 않습니다.
- 앱의 회의 전체 전사는 silence filtering 전 microphone native buffer와
  ScreenCaptureKit system audio native buffer를 별도 임시 CAF에 연속 기록합니다.
- 종료 시 두 임시 CAF를 각각 16 kHz mono signed 16-bit PCM WAV로 변환합니다.
  audio mixing은 수행하지 않습니다.
- source별 chunk WAV, Whisper output, error log도 서로 다른 임시 디렉터리에
  생성하며 성공, 부분 실패, 전체 실패, 취소 후 모두 삭제합니다.
- 앱은 audio data를 backend로 보내지 않고 최종 transcript text만 저장합니다.
- Release DMG는 bundled model을 사용합니다. 비교 POC와 개발 override에서는 사용자가
  설정한 저장소 밖 경로에서 모델을 읽습니다.
- `QA/debug용 source별 WAV 보관`은 기본 비활성화입니다. 사용자가 명시적으로
  활성화한 회의에 한해 microphone/system audio 최종 WAV와 15초 chunk WAV를
  저장소 밖
  `~/Library/Application Support/Mwoham/debug_audio/`에 복사합니다. 이 파일은
  자동 삭제 대상이 아니므로 QA가 끝나면 사용자가 삭제해야 합니다.

Apple Speech 쪽은 기존 앱과 같은 `ko-KR` recognizer를 사용하지만, 실시간 audio
buffer 대신 파일 입력용 `SFSpeechURLRecognitionRequest`를 사용합니다. 따라서 이
결과는 recognizer 품질 비교 기준이며 실시간 meeting path의 완전한 성능 측정은
아닙니다.

## 준비

비교 POC 필요 항목:

- macOS와 full Xcode (`xcrun swiftc`, `codesign`)
- Python 3
- `whisper.cpp`의 `whisper-cli`
- whisper.cpp GGML 모델 파일
- 짧은 한국어 WAV 파일

Homebrew 예시:

```bash
brew install whisper-cpp
command -v whisper-cli
```

소스 빌드 예시:

```bash
git clone https://github.com/ggml-org/whisper.cpp.git ~/src/whisper.cpp
cmake -S ~/src/whisper.cpp -B ~/src/whisper.cpp/build
cmake --build ~/src/whisper.cpp/build --config Release
```

비교 POC는 모델을 자동 다운로드하지 않습니다. whisper.cpp의 모델 다운로드 안내에 따라
`ggml-base.bin`, `ggml-small.bin`, `ggml-large-v3-turbo.bin` 등을 저장소 밖에
준비합니다. 예시 경로:

```text
~/Library/Application Support/Mwoham/stt/models/ggml-large-v3-turbo.bin
```

소스 checkout의 공식 download script를 직접 실행하는 예시:

```bash
mkdir -p "$HOME/Library/Application Support/Mwoham/stt/models"
sh ~/src/whisper.cpp/models/download-ggml-model.sh \
  large-v3-turbo \
  "$HOME/Library/Application Support/Mwoham/stt/models"
```

참고:

- [whisper.cpp 공식 저장소](https://github.com/ggml-org/whisper.cpp)
- [Homebrew whisper-cpp formula](https://formulae.brew.sh/formula/whisper-cpp)

한국어 품질 검증은 우선 `small` 이상 또는 `large-v3-turbo` 모델을 권장합니다.
모델 크기와 처리 시간 차이도 함께 기록합니다.

## 비교 POC 실행

저장소 루트에서 실행합니다.

```bash
python3 scripts/compare_local_stt.py \
  --input "/absolute/path/to/korean-meeting-sample.wav" \
  --language ko \
  --apple-locale ko-KR \
  --model "$HOME/Library/Application Support/Mwoham/stt/models/ggml-large-v3-turbo.bin" \
  --whisper-bin "$(command -v whisper-cli)"
```

출력 형식:

```text
[Apple Speech]
transcript: ...
processing_seconds: 1.234

[Whisper]
transcript: ...
processing_seconds: 2.345
```

첫 실행에서는 `Mwoham Apple Speech POC`의 음성 인식 권한 요청이 표시될 수
있습니다. 거부했거나 권한 상태가 꼬인 경우 시스템 설정의 개인정보 보호 및 보안
> 음성 인식에서 권한을 확인한 뒤 다시 실행합니다.

## 비교 기준

같은 WAV와 같은 실행 환경에서 다음 항목을 수동으로 비교합니다.

- 고유명사, 기술 용어, 숫자, 조사와 문장 경계 정확도
- 의미 없는 한국어 문장 또는 반복 문장 생성 여부
- 누락된 발화와 잘못 추가된 발화
- transcript가 실제 회의 의미를 보존하는지
- 모델별 처리 시간과 Mac 메모리 사용량

한 개 샘플만으로 결론을 내리지 않고, 조용한 음성, 시스템 오디오, 겹친 발화,
배경 소음이 있는 짧은 샘플을 각각 비교하는 것이 좋습니다. raw audio는 검증 후
사용자가 직접 관리하며 repo나 backend에 추가하지 않습니다.

## 실패와 정리

- `whisper-cli not found`: `--whisper-bin`에 빌드된 실행 파일의 절대 경로를
  지정합니다.
- model/input repository 오류: 개인정보와 대용량 파일 유입 방지를 위해 저장소
  내부 경로는 의도적으로 거부합니다.
- Apple Speech authorization 오류: macOS 음성 인식 권한을 확인합니다.
- `recognizer unavailable`: 네트워크, locale 지원, macOS Speech 서비스 상태를
  확인합니다.
- timeout: `--timeout 300`처럼 단계별 제한 시간을 늘립니다.

스크립트가 중단되어도 Python `TemporaryDirectory`가 임시 WAV, helper app,
Whisper output을 정리합니다. 이 POC 실패는 MwohamMac 실행이나 기존 meeting STT에
영향을 주지 않습니다.

앱 meeting 연동에서도 `TemporaryMeetingAudioRecorder`가 소유한 임시 디렉터리를
normal stop, Whisper 실패, provider stop 모두에서 삭제합니다. 앱이 비정상 종료된
경우 운영체제 임시 디렉터리 정책의 영향을 받을 수 있으므로 다음 실행 전
`/private/tmp/mwoham-meeting-whisper-*` 잔존 여부를 확인할 수 있습니다.

## 실제 앱 연동 QA

1. 앱에서 `회의 전체`를 선택하고 Local Whisper 상태가 사용 가능인지 확인합니다.
   Release DMG에서는 bundled runtime/model이 먼저 잡혀야 합니다.
2. `QA/debug용 source별 WAV 보관`은 우선 끈 상태로 회의를 시작합니다.
3. microphone으로 짧은 한국어 문장을 말하면서 ZEP 또는 Chrome에서 한국어
   system audio를 재생합니다. 이어폰 없이 재생해 ScreenCaptureKit 입력과 실제
   microphone 입력을 동시에 확인합니다.
4. 회의를 종료하고 UI의 `Whisper metadata`에서 source별 `chunks`, `accepted`,
   `rejected`, `reject_reasons`, `temporal_merge`, `source_accepted`,
   `processing`, `fallback`을 확인합니다.
5. microphone과 system audio 각각의 `wav`와 `capture` duration 차이가 과도하지
   않은지 확인합니다.
6. 최종 transcript가 source별 전체 묶음이 아니라 `[00:12 microphone]`,
   `[00:15 system_audio]` 같은 시간순 segment 목록으로 저장되는지 확인합니다.
7. `/meeting-transcripts/today`에서 성공 또는 부분 성공 결과가
   `source=local_whisper_full_meeting`으로 저장됐는지 확인합니다.
8. system audio를 재생하지 않은 회의에서도 microphone transcript가 저장되는지,
   microphone 입력이 없는 환경에서도 system audio transcript가 저장되는지
   확인합니다.
9. 무음/잡음 구간과 `"아쩡하쩡하쩡..."` 또는 같은 문장이 반복되는 구간이 있는
   샘플에서 해당 chunk만 rejected되고 정상 발화 chunk는 유지되는지 확인합니다.
10. `"자막 제공 및 자막 제공 및 광고를 포함하고 있습니다."`,
    `"한글자막 by 한글자막 by 한효정"` 같은 자막/광고성 hallucination은
    `subtitle_ad_hallucination`으로 rejected되는지 확인합니다. 정상 회의 문장
    앞/뒤에 독립적으로 붙은 `subtitles by ...` 또는 `자막 제공` 문장은 제거되고
    남은 회의 문장이 유지되는지 확인합니다.
11. 한 source의 모든 chunk를 빈 오디오 또는 반복 결과로 만들어 해당 source만
    최종 결과에서 제외되는지 확인합니다.
12. 두 source의 모든 chunk를 reject시키거나 binary 경로를 잘못 지정해
   `Apple Speech (fallback)`과 `source=apple_speech_full_meeting` 저장을
   확인합니다.

debug WAV가 필요한 경우에만 toggle을 켜고 한 번 더 실행합니다.

```bash
find "$HOME/Library/Application Support/Mwoham/debug_audio" \
  -maxdepth 1 -type f -name '*.wav' -print
```

파일명에 `microphone` 또는 `system_audio`, `full` 또는 `chunk-0000` 같은 label이
포함됩니다. source별 최종 WAV와 chunk WAV를 직접 들어 무음/잡음 구간, 발화 누락,
reject 결과를 비교합니다. 저장소 내부에는 WAV를 복사하지 않습니다. toggle을
다시 끄면 이후 회의는 debug WAV를 남기지 않습니다.

## Daily Report Input 연동

`source=local_whisper_full_meeting`으로 저장된 transcript는 backend report prompt의
`MEETING_MEMO_CONTEXT`와 `PRIORITY_MEETING_TRANSCRIPTS`에 회의 전사 근거로
반영합니다. macOS 앱이 저장한 원문은 다음처럼 timestamp/source label이 붙은
시간순 segment 목록입니다.

```text
[00:00 microphone] ...
[00:15 system_audio] ...
```

report input에서는 이 prefix를 내부 근거로만 사용합니다. prompt에는
`source_type=local_whisper_full_meeting`, `sources=microphone,system_audio`처럼
source 구분만 남기고, content에는 timestamp/source prefix를 제거한 회의 문장을
넣습니다. 긴 전사는 meeting 단위로 dedupe/압축하고, decision, discussion,
follow_up_candidate, utterance로 분류합니다.

manual memo는 계속 `confidence=user_direct` 근거로 우선합니다. local Whisper 전사는
회의 근거로만 다루며, 단순 잡담/농담/휴식 대화나 남은 자막/광고성 문구는 report
input에서 제외하거나 약화합니다. Apple Speech transcript는 기존 표준 transcript
흐름을 유지합니다.

daily report prompt input에는 `CURRENT_WORK_FOCUS`, `MEETING_MEMO_CONTEXT`,
`PRIORITY_MEETING_TRANSCRIPTS`, `WORK_EVIDENCE_BY_TIME` 같은 내부 섹션명이 남을
수 있습니다. 이 라벨은 모델이 근거 우선순위를 이해하기 위한 내부 표식이며, 최종
리포트 본문에는 그대로 출력하지 않습니다. prompt instruction과 report content
cleaner가 내부 라벨명을 사용자에게 보이는 문장으로 노출하지 않도록 막고, 라벨 뒤의
실제 작업/회의 내용만 자연어 요약에 반영합니다.

이 연동은 prompt input 구성만 바꾸며 DB migration, backend endpoint, report API
schema, macOS STT 엔진은 변경하지 않습니다.
