# Local Whisper STT POC와 Meeting 연동

## 목적

이 문서는 다음 두 흐름을 설명합니다.

- 동일한 짧은 한국어 WAV를 Apple Speech와 local `whisper.cpp`에 전달하는 비교 POC
- MwohamMac 회의 전체 전사 종료 시 local Whisper를 우선 사용하는 실제 meeting 흐름

마이크와 시스템 오디오 단독 전사는 기존 Apple Speech를 유지합니다. 회의 전체
전사도 Apple Speech를 실시간 fallback으로 계속 실행하며, Whisper가 설정되고
정상 처리된 경우에만 종료 시 Whisper transcript를 최종 저장합니다.

## MwohamMac Meeting 연동

앱의 `전사 입력`에서 `회의 전체`를 선택하면 Local Whisper 설정이 표시됩니다.

1. `whisper-cli 절대 경로`에 실행 파일 경로를 입력합니다.
2. `GGML model 절대 경로`에 모델 파일 경로를 입력합니다.
3. 회의 전사를 시작합니다.
4. 회의 중에는 Apple Speech가 실시간 transcript를 생성하지만 backend에는 아직
   최종 저장하지 않습니다.
5. `회의 전사 종료`를 누르면 임시 WAV를 닫고 local Whisper를 실행합니다.
6. Whisper 성공 시 `local_whisper_full_meeting` source로 기존
   `/meeting-transcripts` API에 저장합니다.
7. Whisper 미설정, binary/model 오류, 처리 실패, timeout, 빈 결과이면 세션 중
   확보한 Apple Speech 결과를 `apple_speech_full_meeting` source로 저장합니다.

UI의 `STT engine` 행에는 `Local Whisper`, `Apple Speech (fallback)` 또는 현재
설정 상태가 표시됩니다. 경로 변경은 다음 회의 시작부터 적용됩니다.

## 범위와 데이터 정책

- 입력 오디오와 Whisper 모델은 저장소 밖 경로에 있어야 합니다.
- 스크립트는 입력 WAV를 macOS 임시 디렉터리에서 16 kHz mono PCM WAV로 변환합니다.
- Apple Speech helper app, 변환 WAV, Whisper text output은 실행별 임시 디렉터리에만
  만들고 정상 종료와 오류 종료 모두에서 삭제합니다.
- transcript와 처리 시간은 터미널에만 출력하며 backend나 DB에 저장하지 않습니다.
- 원본 오디오는 수정하거나 복사해 저장소에 남기지 않습니다.
- 앱의 회의 전체 전사는 accepted audio buffer를 16 kHz mono PCM 임시 WAV로
  기록하며 Whisper 성공, 실패, 취소 후 모두 해당 임시 디렉터리를 삭제합니다.
- 앱은 audio data를 backend로 보내지 않고 최종 transcript text만 저장합니다.
- 모델은 다운로드하거나 복사하지 않으며 사용자가 설정한 외부 경로에서 읽습니다.

Apple Speech 쪽은 기존 앱과 같은 `ko-KR` recognizer를 사용하지만, 실시간 audio
buffer 대신 파일 입력용 `SFSpeechURLRecognitionRequest`를 사용합니다. 따라서 이
결과는 recognizer 품질 비교 기준이며 실시간 meeting path의 완전한 성능 측정은
아닙니다.

## 준비

필요 항목:

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

모델은 자동 다운로드하지 않습니다. whisper.cpp의 모델 다운로드 안내에 따라
`ggml-base.bin`, `ggml-small.bin`, `ggml-large-v3-turbo.bin` 등을 저장소 밖에
준비합니다. 예시 경로:

```text
~/Library/Application Support/Mwoham/models/ggml-large-v3-turbo.bin
```

소스 checkout의 공식 download script를 직접 실행하는 예시:

```bash
mkdir -p "$HOME/Library/Application Support/Mwoham/models"
sh ~/src/whisper.cpp/models/download-ggml-model.sh \
  large-v3-turbo \
  "$HOME/Library/Application Support/Mwoham/models"
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
  --model "$HOME/Library/Application Support/Mwoham/models/ggml-large-v3-turbo.bin" \
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
