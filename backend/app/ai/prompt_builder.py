from app.schemas.timeline import TimelineResponse
from app.services.privacy_filter import PrivacyFilter, get_privacy_filter
from app.services.screen_observation_summarizer import SAFE_UNCLEAR_INFERENCE


class PromptBuilder:
    SELF_SERVICE_MARKERS = (
        "127.0.0.1:8765",
        "localhost:8765",
        "대시보드 - 뭐함",
        "타임라인 - 뭐함",
        "리포트 - 뭐함",
        "설정 - 뭐함",
        "작업 기록 자동화 서비스",
    )

    def __init__(self, privacy_filter: PrivacyFilter) -> None:
        self.privacy_filter = privacy_filter

    def build_daily_report_prompt(self, timeline: TimelineResponse) -> str:
        compressed_timeline = self._compress_timeline(timeline)
        safe_timeline = self.privacy_filter.mask(compressed_timeline)
        return "\n".join(
            [
                "다음은 개인 로컬 작업 기록 에이전트가 만든 일일 압축 타임라인입니다.",
                "원본 화면, 음성, 스크린샷, 오디오 파일은 포함하지 않았습니다.",
                "민감할 수 있는 API key, token, password, secret 패턴은 마스킹되었습니다.",
                "",
                "요청:",
                "- 자연스러운 한국어 업무 리포트를 Markdown 형식으로 작성하세요.",
                "- 과장하지 말고 타임라인에 있는 사실만 사용하세요.",
                "- 비어 있는 섹션은 억지로 늘리지 말고 '확인된 내용 없음'처럼 짧게 처리하세요.",
                "- 빈 타임라인이면 '기록된 작업이 없습니다.' 한 문장만 반환하세요.",
                "- 앱 이름은 작업 도구나 환경 정보로만 참고하세요.",
                "- 'Codex 앱에서', 'Chrome 앱에서', 'VSCode 앱에서'처럼 앱이 업무 주체인 듯한 "
                "표현을 피하세요.",
                "- 앱 이름보다 실제 작업 내용, 결정사항, 문제 해결 과정을 중심으로 요약하세요.",
                "- 아래 섹션 순서를 지키세요.",
                "",
                "리포트 구조:",
                "## 오늘 한 일 요약",
                "## 시간대별 작업 흐름",
                "## 주요 트러블슈팅",
                "## 회의/메모에서 나온 결정사항",
                "## 다음 작업 후보",
                "",
                "타입별 입력 의미:",
                "- EVENT: 앱/터미널/윈도우 등에서 관찰된 작업 이벤트입니다.",
                "- ACTIVITY_SEGMENT: 같은 앱/창이 유지된 보조 작업 컨텍스트입니다. "
                "주요 작업 내용 판단에는 SCREEN_OCR의 AI 추론과 MEMO를 우선 참고하세요.",
                "- MEMO: 사용자가 직접 남긴 메모입니다.",
                "- SCREEN_OCR: 화면 OCR 기반 AI 추론과 감지 키워드입니다. "
                "원본 이미지는 포함하지 않았고, ai_inference를 우선 참고하세요.",
                "- MEETING: 회의 시작/종료 등 회의 상태 이벤트입니다.",
                "- TRANSCRIPT: 회의 전사 텍스트입니다. 원본 음성은 포함하지 않았습니다.",
                "",
                "압축 타임라인:",
                safe_timeline,
            ]
        )

    def _compress_timeline(self, timeline: TimelineResponse) -> str:
        if not timeline.items:
            return f"DATE: {timeline.date.isoformat()}\nEMPTY: 기록된 작업이 없습니다."

        report_items = [
            item
            for item in timeline.items
            if item.type != "activity_segment" and not self._is_self_service_screen_item(item)
        ]
        activity_segments = [item for item in timeline.items if item.type == "activity_segment"]

        lines = [f"DATE: {timeline.date.isoformat()}", f"TOTAL_ITEMS: {len(report_items)}"]
        for item in report_items:
            lines.append(self._format_timeline_item(item))
        environment_summary = self._format_activity_environment_summary(activity_segments)
        if environment_summary:
            lines.append(environment_summary)
        return "\n".join(lines)

    def _format_timeline_item(self, item) -> str:
        timestamp = item.timestamp.isoformat()
        if item.type == "event":
            return (
                f"- EVENT | time={timestamp} | source={item.source or '-'} | "
                f"app={item.app_name or '-'} | window={item.window_title or '-'} | "
                f"content={item.content}"
            )
        if item.type == "activity_segment":
            ended_at = item.ended_at.isoformat() if item.ended_at else "-"
            return (
                f"- ACTIVITY_SEGMENT | start={timestamp} | end={ended_at} | "
                f"duration_seconds={item.duration_seconds or 0} | "
                f"samples={item.sample_count or 0} | "
                f"app={item.app_name or '-'} | window={item.window_title or '-'}"
            )
        if item.type == "memo":
            return (
                f"- MEMO | time={timestamp} | linked_type={item.linked_type or '-'} | "
                f"linked_id={item.linked_id or '-'} | content={item.content}"
            )
        if item.type == "screen_ocr":
            ocr_excerpt = self._truncate(item.ocr_text or item.content, 300)
            inference = self._safe_inference(item.ai_inference or item.content)
            return (
                f"- SCREEN_OCR | time={timestamp} | app={item.app_name or '-'} | "
                f"keywords={item.detected_keywords or []} | "
                f"inference={inference} | "
                f"ocr_excerpt={ocr_excerpt}"
            )
        if item.type == "meeting":
            return (
                f"- MEETING | time={timestamp} | meeting_id={item.meeting_id or item.id} | "
                f"content={item.content}"
            )
        if item.type == "transcript":
            return (
                f"- TRANSCRIPT | time={timestamp} | meeting_id={item.meeting_id or '-'} | "
                f"speaker={item.speaker or '-'} | confidence={item.confidence or '-'} | "
                f"text={item.content}"
            )
        return f"- {item.type.upper()} | time={timestamp} | content={item.content}"

    def _format_activity_environment_summary(self, items) -> str:
        if not items:
            return ""

        duration_by_environment: dict[str, int] = {}
        for item in items:
            environment = " / ".join(
                value
                for value in [item.app_name or "알 수 없는 앱", item.window_title]
                if value
            )
            duration_by_environment[environment] = duration_by_environment.get(environment, 0) + (
                item.duration_seconds or 0
            )

        summaries = sorted(
            duration_by_environment.items(),
            key=lambda item: item[1],
            reverse=True,
        )[:5]
        summary_text = "; ".join(
            f"{environment} {duration_seconds}초"
            for environment, duration_seconds in summaries
        )
        return f"- ACTIVITY_ENVIRONMENT_SUMMARY | {summary_text}"

    def _is_self_service_screen_item(self, item) -> bool:
        if item.type != "screen_ocr":
            return False
        values = [item.app_name, item.window_title, item.content, item.ocr_text, item.ai_inference]
        combined_text = "\n".join(value for value in values if value).lower()
        return any(marker.lower() in combined_text for marker in self.SELF_SERVICE_MARKERS)

    def _truncate(self, text: str, limit: int) -> str:
        if len(text) <= limit:
            return text
        return text[:limit].rstrip() + "..."

    def _safe_inference(self, inference: str | None) -> str:
        if not inference:
            return "-"
        if self._has_unbalanced_delimiter(inference):
            return SAFE_UNCLEAR_INFERENCE
        if not self._ends_with_complete_korean_sentence(inference):
            return SAFE_UNCLEAR_INFERENCE
        return inference

    def _has_unbalanced_delimiter(self, text: str) -> bool:
        delimiter_pairs = [("'", "'"), ('"', '"'), ("`", "`"), ("(", ")"), ("[", "]"), ("{", "}")]
        for opener, closer in delimiter_pairs:
            if opener == closer:
                if text.count(opener) % 2 != 0:
                    return True
            elif text.count(opener) != text.count(closer):
                return True
        return False

    def _ends_with_complete_korean_sentence(self, text: str) -> bool:
        complete_endings = (
            "합니다.",
            "있습니다.",
            "보입니다.",
            "어렵습니다.",
            "진행하고 있습니다.",
            "확인하고 있습니다.",
            "진행 중입니다.",
            "확인 중입니다.",
            "같습니다.",
            "않습니다.",
            "됩니다.",
            "했습니다.",
        )
        return text.endswith(complete_endings)


def get_prompt_builder() -> PromptBuilder:
    return PromptBuilder(privacy_filter=get_privacy_filter())
