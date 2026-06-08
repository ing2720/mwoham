# MVP QA 체크리스트

이 문서는 MVP를 실제 사용 시나리오 기준으로 검증하기 위한 체크리스트입니다.
기능 구현 문서가 아니라, 로컬 환경에서 무엇을 확인해야 하는지와 실패 시 의심 원인을 정리합니다.

## 사전 준비

- macOS 앱과 백엔드는 같은 머신에서 실행합니다.
- 백엔드는 `http://127.0.0.1:8765`에서 실행합니다.
- 화면 OCR 검증 전 macOS 화면 기록 권한을 허용합니다.
- 회의 전사 검증 전 선택한 source에 맞는 권한을 허용합니다.
  - 마이크: 음성 인식, 마이크
  - 시스템 오디오: 음성 인식, 화면 기록
  - 회의 전체: 음성 인식, 마이크, 화면 기록
- 실제 Gemini 호출은 quota를 소모합니다. 기본 정책상 개별 ScreenObservation AI 해석은 비활성화되어 있고, 일일 리포트 생성에 Gemini 호출을 우선 사용합니다.
- `LOCAL_API_TOKEN`을 설정한 경우 모든 보호 API 호출에 `Authorization: Bearer <token>` 헤더를 추가합니다.

## 1. 백엔드 실행

명령:

```bash
cd backend
uv sync
uv run alembic upgrade head
uv run uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload
```

확인:

```bash
curl http://127.0.0.1:8765/health
curl http://127.0.0.1:8765/status
```

정상 기대 결과:

- `/health`가 `200 OK`를 반환합니다.
- `/status`가 현재 기록 상태를 반환합니다.
- 브라우저에서 `http://127.0.0.1:8765/dashboard`가 열립니다.

실패 시 의심 원인:

- 포트 `8765`가 이미 사용 중입니다.
- `uv sync`가 끝나지 않았거나 가상환경 의존성이 없습니다.
- migration이 적용되지 않았습니다.
- `LOCAL_API_TOKEN` 설정 후 헤더 없이 호출했습니다.

## 2. Mac 앱 실행

명령:

```bash
xcodebuild \
  -project mac-client/MwohamMac/MwohamMac.xcodeproj \
  -scheme MwohamMac \
  -destination platform=macOS \
  -derivedDataPath /private/tmp/MwohamMacDerivedData \
  build
```

확인:

- Xcode에서 `MwohamMac` scheme을 실행합니다.
- 일반 창에서 백엔드 연결 상태가 `연결됨`으로 보입니다.
- 메뉴바 항목이 표시됩니다.
- 메뉴바에서 플로팅 위젯을 열고 닫을 수 있습니다.

실패 시 의심 원인:

- 백엔드가 실행 중이 아닙니다.
- 앱 sandbox/권한 설정 때문에 로컬 API 호출이 막혔습니다.
- `LOCAL_API_TOKEN`이 백엔드에만 설정되어 있고 앱 환경에는 전달되지 않았습니다.

## 3. 기록 시작, 일시정지, 재개, 종료

명령:

```bash
curl -X POST http://127.0.0.1:8765/recording/start
curl http://127.0.0.1:8765/status
curl -X POST http://127.0.0.1:8765/recording/pause
curl -X POST http://127.0.0.1:8765/recording/resume
curl -X POST http://127.0.0.1:8765/recording/stop
```

UI 확인:

- Mac 앱의 `기록 시작`, `일시정지`, `재개`, `기록 종료` 버튼이 상태에 맞게 동작합니다.
- 플로팅 위젯의 접힌/펼친 상태에서도 상태와 버튼이 맞게 보입니다.
- 기록 시간이 active 상태에서 갱신됩니다.

정상 기대 결과:

- `status`가 `active -> paused -> active -> stopped` 순서로 변합니다.
- stopped 상태에서는 기록 시간이 `기록 중 아님`으로 보입니다.

실패 시 의심 원인:

- 이미 active 세션이 있어 중복 시작이 거부되었습니다.
- active 세션 없이 pause/resume/stop을 호출했습니다.
- 앱 화면이 갱신되지 않았다면 새로고침을 누릅니다.

## 4. ActivitySegment 저장 확인

절차:

1. 기록을 시작합니다.
2. Chrome, PyCharm, Xcode 등 여러 앱으로 전환합니다.
3. 각 앱/창을 몇 초 이상 유지합니다.

확인 명령:

```bash
curl "http://127.0.0.1:8765/activity-segments?date=$(date +%F)"
curl "http://127.0.0.1:8765/timeline/today/detail?date=$(date +%F)"
```

정상 기대 결과:

- `activity-segments`에 `app_name`, `window_title`, `duration_seconds`, `sample_count`가 저장됩니다.
- 상세 타임라인에는 `activity_segment`가 보입니다.
- 기본 타임라인에는 ActivitySegment가 직접 나열되지 않습니다.

실패 시 의심 원인:

- 기록 상태가 `active`가 아닙니다.
- Mac 앱이 실행 중이 아니거나 ActiveWindowCollector가 시작되지 않았습니다.
- 앱/창 제목 접근 권한이 부족해 `window_title`이 비어 있을 수 있습니다.

## 5. PrivateApp 제외 확인

설정 명령:

```bash
curl -X POST http://127.0.0.1:8765/settings/private-apps \
  -H "Content-Type: application/json" \
  -d '{"app_name":"Discord","match_type":"exact","is_enabled":true}'
curl http://127.0.0.1:8765/settings/private-apps
```

절차:

1. 기록을 시작합니다.
2. Discord 또는 등록한 제외 앱을 활성화합니다.
3. 다시 일반 앱으로 돌아옵니다.

확인:

```bash
curl "http://127.0.0.1:8765/activity-segments?date=$(date +%F)"
curl "http://127.0.0.1:8765/timeline/today?date=$(date +%F)"
```

정상 기대 결과:

- 제외 앱은 새 ActivitySegment로 저장되지 않습니다.
- Mac 앱 UI에는 구체 앱/창 이름 대신 `비공개 앱` 또는 `비공개 앱 사용 중`이 표시됩니다.
- 기본 타임라인과 리포트 입력에 제외 앱의 구체 정보가 나오지 않습니다.

실패 시 의심 원인:

- `match_type`이 실제 앱 이름과 맞지 않습니다.
- PrivateApp 규칙이 `is_enabled=false`입니다.
- 이미 저장된 과거 데이터는 자동 삭제되지 않습니다.

## 6. OCR 수집 확인

사전 확인:

- macOS 시스템 설정에서 MwohamMac 또는 Xcode 실행 앱에 화면 기록 권한을 부여합니다.
- 기록 상태가 `active`여야 합니다.
- PrivateApp 또는 MwohamMac 자기 자신이 활성 상태면 OCR은 중지됩니다.

확인 명령:

```bash
curl "http://127.0.0.1:8765/screen-observations?date=$(date +%F)&limit=20"
```

정상 기대 결과:

- `ocr_text`, `detected_keywords`, `frame_hash`가 저장됩니다.
- 기본 설정에서는 `ai_inference`가 `null`일 수 있습니다.
- OCR 상태는 `OCR 저장됨`, `OCR 텍스트 부족`, `OCR 품질 낮음`, `비공개 앱으로 OCR 중지`, `권한 필요` 중 상황에 맞게 표시됩니다.

실패 시 의심 원인:

- 화면 기록 권한이 없습니다.
- 기록 상태가 `active`가 아닙니다.
- OCR 텍스트가 너무 짧거나 품질 필터에 걸렸습니다.
- 같은 화면이 반복되어 중복 저장이 생략되었습니다.
- PrivateApp 또는 MwohamMac 자기 자신이 활성 상태입니다.

## 7. 기본 타임라인 확인

확인:

```bash
curl "http://127.0.0.1:8765/timeline/today?date=$(date +%F)"
open "http://127.0.0.1:8765/timeline"
```

정상 기대 결과:

- 기본 타임라인은 작업 흐름 중심으로 간결하게 보입니다.
- ManualMemo는 표시됩니다.
- 일반 WorkEvent는 표시됩니다.
- `source="mac_active_window"` WorkEvent는 표시되지 않습니다.
- ActivitySegment는 직접 나열되지 않습니다.
- ScreenObservation은 raw OCR 전문 대신 `ai_inference` 또는 `화면 텍스트 수집됨`으로 표시됩니다.
- 자기 서비스 화면 OCR은 기본 타임라인에서 제외됩니다.
- 시간은 한국시간 기준으로 표시됩니다.

실패 시 의심 원인:

- 상세 타임라인과 혼동했습니다.
- OCR이 저장되지 않았거나 기본 타임라인 필터에 의해 숨겨졌습니다.
- 자기 서비스 화면만 수집되어 기본 타임라인에 표시할 항목이 없습니다.

## 8. 상세 타임라인 확인

확인:

```bash
curl "http://127.0.0.1:8765/timeline/today/detail?date=$(date +%F)"
open "http://127.0.0.1:8765/timeline/detail"
```

정상 기대 결과:

- 제목에 `상세 타임라인`이 표시됩니다.
- ActivitySegment가 표시됩니다.
- ScreenObservation은 OCR 발췌 중심으로 표시됩니다.
- Memo, WorkEvent, Meeting, Transcript도 확인할 수 있습니다.

실패 시 의심 원인:

- 웹 상세 화면은 `/timeline/detail`, API 상세 타임라인은 `/timeline/today/detail`입니다.
- ActivitySegment가 없다면 기록 상태가 active가 아니었거나 Mac 앱 collector가 동작하지 않았습니다.

## 9. 회의 전사 확인

사전 확인:

- backend가 실행 중이어야 합니다.
- Mac 앱이 실행 중이어야 합니다.
- macOS 시스템 설정에서 MwohamMac 또는 Xcode 실행 앱에 선택한 전사 source별 권한을 부여합니다.

절차:

1. Mac 앱에서 전사 입력 source를 선택합니다.
   - 마이크
   - 시스템 오디오
   - 회의 전체
2. Mac 앱에서 `회의 전사 시작`을 누릅니다.
3. 권한 요청이 표시되면 필요한 권한을 허용합니다.
4. 마이크 source에서는 한국어로 짧은 문장과 의미 있는 문장을 말합니다.
5. 시스템 오디오 source에서는 브라우저, ZEP, Meet, Zoom 등에서 한국어 음성을 재생합니다.
6. 회의 전체 source에서는 마이크 발화와 시스템 오디오 재생을 함께 확인합니다.
7. Mac 앱에서 최근 전사 텍스트가 표시되는지 확인합니다.
8. `회의 전사 종료`를 누릅니다.

확인 명령:

```bash
curl "http://127.0.0.1:8765/meeting-transcripts/today"
curl "http://127.0.0.1:8765/status"
```

정상 기대 결과:

- `/status`에서 회의 중에는 `meeting_mode=true`로 표시됩니다.
- `/meeting-transcripts/today`에 선택한 source에 맞는 transcript가 저장됩니다.
  - `apple_speech_microphone`
  - `apple_speech_system_audio`
  - `apple_speech_full_meeting`
- 원본 오디오 파일은 저장되지 않습니다.
- backend로 audio data가 전송되지 않고 transcript text만 저장됩니다.
- 회의 전사 종료 후 앱 상태가 `회의 전사 종료됨` 또는 `전사 저장 후 종료됨` 계열로 표시됩니다.

실패 시 의심 원인:

- 음성 인식 권한 또는 마이크 권한이 없습니다.
- 권한을 허용한 뒤 앱을 재실행하지 않았습니다.
- 너무 짧은 전사 조각이 저장 품질 정책에 의해 제외되었습니다.
- backend가 실행 중이 아니거나 Local API Token 설정이 앱과 맞지 않습니다.

## 10. 자동 Dev Tracking 확인

사전 확인:

- backend가 실행 중이어야 합니다.
- Mac 앱이 실행 중이어야 합니다.
- uv와 git이 설치되어 있어야 합니다.
- 앱 설정의 Dev Tracking 추적 repo 경로가 비어 있거나 유효한 Git repo여야 합니다.

절차:

1. PyCharm, Visual Studio Code, Code, Terminal, iTerm, iTerm2, Cursor 중 하나를 활성화합니다.
2. 앱 상태, 메뉴바, 플로팅 위젯에서 Dev Tracking 상태를 확인합니다.
3. Git repo에서 파일을 수정합니다.
4. debounce/interval 이후 DevEvent 저장 여부를 확인합니다.
5. Chrome 같은 비개발 앱으로 이동한 뒤 grace period 후 watcher가 종료되는지 확인합니다.

확인 명령:

```bash
curl "http://127.0.0.1:8765/dev-events/today?date=$(date +%F)"
curl "http://127.0.0.1:8765/timeline/today/detail?date=$(date +%F)"
```

정상 기대 결과:

- 개발 도구 활성화 시 `Dev Tracking: 감시 시작` 또는 `Dev Tracking: 개발 도구 감지됨, 감시 중`이 표시됩니다.
- 변경이 없으면 `Dev Tracking: 변경 없음`이 표시됩니다.
- 변경 직후에는 `Dev Tracking: 변경 감지, 안정화 대기 중`이 표시될 수 있습니다.
- 안정화 후 `Git 변경 감지: ...` 요약이 표시됩니다.
- watcher가 같은 signature를 반복 저장하지 않습니다.
- `*.swp`, `*.swo`, `.DS_Store`, cache, coverage 산출물만 있는 경우 DevEvent가 저장되지 않습니다.
- DevEvent details에는 diff_summary 같은 안전한 메타데이터가 저장되고 raw diff 본문은 저장되지 않습니다.

실패 시 의심 원인:

- 활성 앱이 개발 도구 목록에 없습니다.
- repo path가 존재하지 않거나 Git repo가 아닙니다.
- 앱 실행 환경 PATH에서 uv 또는 git을 찾지 못합니다.
- backend 경로 fallback이 현재 실행 위치와 맞지 않습니다.
- watcher stdout/stderr에 오류가 표시됐는지 확인합니다.

## 11. 리포트 생성 확인

확인 명령:

```bash
curl -X POST http://127.0.0.1:8765/reports/daily \
  -H "Content-Type: application/json" \
  -d "{\"date\":\"$(date +%F)\"}"
curl "http://127.0.0.1:8765/reports/today?date=$(date +%F)"
```

웹 확인:

- `http://127.0.0.1:8765/reports`에서 `오늘 리포트 생성`을 누릅니다.
- 생성된 리포트 상세 화면을 엽니다.

정상 기대 결과:

- Gemini 호출에 성공하면 `created_by="ai"`입니다.
- Gemini API key가 없거나 quota 초과면 `created_by="system"` fallback 리포트가 생성됩니다.
- fallback 리포트는 raw timeline 전체 덤프가 아니라 요약, 주요 메모, 주요 화면 관찰, 주요 작업 환경 중심으로 짧게 생성됩니다.
- 자동 watcher 기반 `git_snapshot`은 report input에서 20분 버킷과 branch 기준으로 압축됩니다.
- report 생성 시점의 `CURRENT_GIT_CHANGE_HINTS`와 `CURRENT_GIT_DIFF_CONTEXT`가 있으면 구체 작업 의도 파악에 우선 사용됩니다.
- raw git diff는 DB, DevEvent, log, Report.content에 그대로 저장되지 않습니다.

실패 시 의심 원인:

- `GEMINI_API_KEY`가 없습니다.
- Gemini quota가 초과되었습니다.
- Gemini 모델명이 잘못되었습니다.
- 타임라인에 리포트에 넣을 데이터가 거의 없습니다.

## 12. PDF 다운로드 확인

1. 리포트를 생성합니다.
2. 리포트 ID를 확인합니다.

명령:

```bash
REPORT_ID=1
curl -X POST "http://127.0.0.1:8765/reports/${REPORT_ID}/export" \
  -H "Content-Type: application/json" \
  -d '{"export_format":"pdf"}'
curl -OJ "http://127.0.0.1:8765/reports/${REPORT_ID}/download?format=pdf"
```

정상 기대 결과:

- PDF 파일이 다운로드됩니다.
- export 파일은 `backend/exports/reports` 또는 `REPORT_EXPORT_DIR`에 저장됩니다.
- 다운로드 파일이 PDF viewer에서 열립니다.

실패 시 의심 원인:

- 리포트 ID가 존재하지 않습니다.
- PDF 생성 의존성 또는 시스템 폰트 문제가 있습니다.
- export 디렉터리 쓰기 권한이 없습니다.

## 13. 원본 이미지/오디오/raw diff 미저장 확인

확인 명령:

```bash
find . \
  -path './.git' -prune -o \
  -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.tiff' \) \
  -print
git status --short
```

정상 기대 결과:

- OCR 수집 때문에 새 스크린샷 이미지 파일이 생성되지 않습니다.
- backend에는 OCR 텍스트만 저장됩니다.
- `git status --short`에 캡처 이미지 파일이 나타나지 않습니다.
- 회의 전사 때문에 원본 오디오 파일이나 raw audio buffer 파일이 생성되지 않습니다.
- DevEvent에는 raw git diff 본문이나 파일 내용이 저장되지 않습니다.

실패 시 의심 원인:

- 개발 중 수동으로 만든 캡처 파일이 남아 있습니다.
- 외부 캡처 도구가 파일을 저장했습니다.
- 앱 코드가 아닌 별도 디버깅 스크립트가 이미지를 저장했습니다.

## 14. Gemini quota 초과 fallback 확인

확인 명령:

```bash
cd backend
uv run python -c "from app.ai.gemini_client import GeminiClient; from app.core.config import settings; c=GeminiClient(api_key=settings.gemini_api_key, model=settings.gemini_model, max_output_tokens=128); r=c.generate_text_result('한국어 한 문장으로 답하세요.'); print({'has_text': bool(r.text), 'error_reason': r.error_reason, 'status_code': r.status_code, 'finish_reason': r.finish_reason})"
```

정상 기대 결과:

- quota가 충분하면 `has_text=True`입니다.
- quota 초과 시 `error_reason='quota_exceeded'`, `status_code=429`가 확인됩니다.
- `/reports/daily`는 실패 reason을 로그에 남기고 `created_by="system"` fallback 리포트를 생성합니다.
- API key 값은 로그와 응답에 출력되지 않습니다.

실패 시 의심 원인:

- `.env`가 로드되지 않았습니다.
- API key가 잘못되었습니다.
- `GEMINI_MODEL`이 계정에서 사용할 수 없는 모델입니다.
- 네트워크 연결 또는 Google API 접근이 실패했습니다.

## 개발용 검증 명령

백엔드 전체 검증:

```bash
cd backend
uv run ruff check .
uv run pytest
uv run alembic check
cd ..
git diff --check
```

Mac 앱 빌드 검증:

```bash
xcodebuild \
  -project mac-client/MwohamMac/MwohamMac.xcodeproj \
  -scheme MwohamMac \
  -destination platform=macOS \
  -derivedDataPath /private/tmp/MwohamMacDerivedData \
  build
```

자주 보는 API:

```bash
curl http://127.0.0.1:8765/status
curl "http://127.0.0.1:8765/timeline/today?date=$(date +%F)"
curl "http://127.0.0.1:8765/timeline/today/detail?date=$(date +%F)"
curl "http://127.0.0.1:8765/screen-observations?date=$(date +%F)&limit=20"
curl "http://127.0.0.1:8765/activity-segments?date=$(date +%F)"
curl "http://127.0.0.1:8765/reports/today?date=$(date +%F)"
```
