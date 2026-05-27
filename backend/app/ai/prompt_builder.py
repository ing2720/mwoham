from app.schemas.timeline import TimelineResponse
from app.services.privacy_filter import PrivacyFilter, get_privacy_filter


class PromptBuilder:
    def __init__(self, privacy_filter: PrivacyFilter) -> None:
        self.privacy_filter = privacy_filter

    def build_daily_report_prompt(self, timeline: TimelineResponse) -> str:
        compressed_timeline = self._compress_timeline(timeline)
        safe_timeline = self.privacy_filter.mask(compressed_timeline)
        return "\n".join(
            [
                "다음은 개인 로컬 작업 기록 에이전트가 만든 압축 타임라인입니다.",
                "원본 화면, 음성, 스크린샷, 오디오 파일은 포함하지 않았습니다.",
                "민감할 수 있는 API key, token, password, secret 패턴은 마스킹되었습니다.",
                "",
                "요청:",
                "- 한국어로 일일 작업 리포트를 작성하세요.",
                "- 과장하지 말고 타임라인에 있는 사실만 사용하세요.",
                "- 섹션은 요약, 주요 작업, 메모, 다음 액션 순서로 작성하세요.",
                "",
                "압축 타임라인:",
                safe_timeline,
            ]
        )

    def _compress_timeline(self, timeline: TimelineResponse) -> str:
        if not timeline.items:
            return f"{timeline.date.isoformat()} 타임라인 항목 없음"

        lines = [f"date={timeline.date.isoformat()} total={timeline.total}"]
        for item in timeline.items:
            label = item.type
            source = f" source={item.source}" if item.source else ""
            app_name = f" app={item.app_name}" if item.app_name else ""
            keywords = (
                f" keywords={item.detected_keywords}"
                if item.type == "screen_ocr" and item.detected_keywords
                else ""
            )
            inference = (
                f" inference={item.ai_inference}"
                if item.type == "screen_ocr" and item.ai_inference
                else ""
            )
            speaker = (
                f" speaker={item.speaker}" if item.type == "transcript" and item.speaker else ""
            )
            meeting = f" meeting_id={item.meeting_id}" if item.meeting_id else ""
            lines.append(
                f"- {item.timestamp.isoformat()} "
                f"type={label}{source}{app_name}{keywords}{inference}{speaker}{meeting}: "
                f"{item.content}"
            )
        return "\n".join(lines)


def get_prompt_builder() -> PromptBuilder:
    return PromptBuilder(privacy_filter=get_privacy_filter())
