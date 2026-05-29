import re

from app.ai.gemini_client import GeminiClient
from app.core.config import settings
from app.services.privacy_filter import PrivacyFilter, get_privacy_filter

SAFE_UNCLEAR_INFERENCE = "화면 내용만으로는 구체적인 작업을 판단하기 어렵습니다."


class ScreenObservationSummarizer:
    def __init__(
        self,
        *,
        client: GeminiClient,
        privacy_filter: PrivacyFilter,
        minimum_text_length: int = 20,
        max_ocr_text_length: int = 3000,
        max_inference_length: int = 220,
    ) -> None:
        self.client = client
        self.privacy_filter = privacy_filter
        self.minimum_text_length = minimum_text_length
        self.max_ocr_text_length = max_ocr_text_length
        self.max_inference_length = max_inference_length

    def summarize(
        self,
        *,
        ocr_text: str | None,
        app_name: str | None,
        window_title: str | None,
    ) -> str | None:
        cleaned_ocr_text = self._clean_text(ocr_text)
        if not self._has_enough_text(cleaned_ocr_text):
            return SAFE_UNCLEAR_INFERENCE

        if self._is_noisy_or_mixed_context(cleaned_ocr_text):
            return self._fallback_inference(app_name=app_name, window_title=window_title)

        prompt = self._build_prompt(
            ocr_text=self._limit_text(cleaned_ocr_text, self.max_ocr_text_length),
            app_name=app_name,
            window_title=window_title,
        )
        if self.client.is_configured:
            inference = self.client.generate_text(prompt)
            if inference:
                cleaned_inference = self._clean_inference(inference)
                if cleaned_inference:
                    return cleaned_inference

        return self._fallback_inference(
            app_name=app_name,
            window_title=window_title,
        )

    def _build_prompt(
        self,
        *,
        ocr_text: str,
        app_name: str | None,
        window_title: str | None,
    ) -> str:
        safe_ocr_text = self.privacy_filter.mask(ocr_text)
        return "\n".join(
            [
                "다음은 로컬 macOS 앱이 화면에서 추출한 OCR 텍스트와 앱/창 메타데이터입니다.",
                "원본 화면 이미지나 스크린샷은 포함하지 않았고, 텍스트만 제공합니다.",
                "사용자가 지금 어떤 작업을 하고 있는지 자연스러운 한국어 1~2문장으로만 추론하세요.",
                "OCR 텍스트 일부를 그대로 길게 반복하거나 따옴표로 인용하지 마세요.",
                "브라우저 주소, 버튼, 사이드바, 채팅 입력 안내, 로그 조각은 "
                "핵심 작업이 아니면 무시하세요.",
                "app_name과 window_title은 작업 환경 참고용으로만 사용하세요.",
                "확실하지 않으면 단정하지 말고 '~로 보입니다.' 또는 "
                "'화면 내용만으로는 구체적인 작업을 판단하기 어렵습니다.'라고 쓰세요.",
                "문장은 반드시 '합니다.', '확인하고 있습니다.', '진행하고 있습니다.', "
                "'보입니다.', '어렵습니다.'처럼 완성된 종결형으로 끝내세요.",
                "출력에는 Markdown, 목록, 코드블록, 접두어를 넣지 마세요.",
                "앱 이름은 도구/환경 정보로만 참고하고, 실제 작업 내용을 우선하세요.",
                "",
                f"app_name: {app_name or '-'}",
                f"window_title: {window_title or '-'}",
                "ocr_text:",
                safe_ocr_text,
            ]
        )

    def _fallback_inference(
        self,
        *,
        app_name: str | None,
        window_title: str | None,
    ) -> str:
        app = (app_name or "").strip()
        title = (window_title or "").strip()
        context = f"{app} {title}".lower()
        display_app = app or "현재 앱"

        if any(keyword in context for keyword in ["pycharm", "xcode", "vscode", "cursor"]):
            return f"사용자는 {display_app}에서 프로젝트 코드 변경 내용을 확인하고 있습니다."
        if any(keyword in context for keyword in ["127.0.0.1", "localhost", "dashboard", "mwoham"]):
            return f"사용자는 {display_app}에서 작업 기록 자동화 서비스 화면을 확인하고 있습니다."
        dev_error_keywords = ["pytest", "ruff", "alembic", "exception", "error"]
        if any(keyword in context for keyword in dev_error_keywords):
            return f"사용자는 {display_app}에서 개발 환경의 오류나 테스트 결과를 확인하고 있습니다."
        if any(keyword in context for keyword in ["chrome", "safari", "browser", "google chrome"]):
            return f"사용자는 {display_app}에서 웹 화면의 작업 내용을 확인하고 있습니다."

        return SAFE_UNCLEAR_INFERENCE

    def _clean_text(self, text: str | None) -> str:
        if not text:
            return ""
        lines = []
        for line in text.splitlines():
            cleaned_line = self._single_line(line)
            if cleaned_line and not self._is_noise_line(cleaned_line):
                lines.append(cleaned_line)
        return "\n".join(lines)

    def _has_enough_text(self, text: str) -> bool:
        meaningful_count = sum(1 for character in text if character.isalnum())
        return meaningful_count >= self.minimum_text_length

    def _clean_inference(self, inference: str) -> str | None:
        cleaned = self._single_line(inference)
        if not cleaned:
            return None
        cleaned = self._strip_output_prefix(cleaned)
        limited = self._limit_to_complete_sentences(cleaned)
        if not self._is_valid_inference(limited):
            return None
        return limited

    def _strip_output_prefix(self, text: str) -> str:
        return re.sub(r"^(?:답변|요약|추론|AI 추정)\s*[:：]\s*", "", text).strip()

    def _limit_to_complete_sentences(self, text: str) -> str:
        sentence_matches = list(re.finditer(r"[^.!?。]+[.!?。]", text))
        if not sentence_matches:
            return text if len(text) <= self.max_inference_length else ""

        sentences = []
        total_length = 0
        for match in sentence_matches[:2]:
            sentence = match.group(0).strip()
            next_length = total_length + len(sentence) + (1 if sentences else 0)
            if next_length > self.max_inference_length:
                break
            sentences.append(sentence)
            total_length = next_length

        return " ".join(sentences)

    def _is_valid_inference(self, text: str) -> bool:
        if len(text) < 18 or len(text) > self.max_inference_length:
            return False
        if self._has_unbalanced_delimiter(text):
            return False
        return self._ends_with_complete_korean_sentence(text)

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
            "검토하고 있습니다.",
            "작성하고 있습니다.",
            "수정하고 있습니다.",
            "테스트하고 있습니다.",
            "디버깅하고 있습니다.",
            "처리하고 있습니다.",
            "준비하고 있습니다.",
            "사용하고 있습니다.",
            "진행 중입니다.",
            "확인 중입니다.",
            "같습니다.",
            "않습니다.",
            "됩니다.",
            "했습니다.",
        )
        return text.endswith(complete_endings)

    def _is_noise_line(self, line: str) -> bool:
        noise_patterns = [
            r"(?i)chatgpt can make mistakes",
            r"(?i)message chatgpt",
            r"(?i)what can i help with",
            r"무엇을 도와드릴까요",
            r"메시지 입력",
            r"nw_path_necp_check",
            r"UserInfo=.*NSDebugDescription",
            r"NSDebugDescription",
            r"CoreSimulatorService connection became invalid",
            r"DVTFilePathFSEvents",
            r"^\d{1,2}:\d{2}(\s?[AP]M)?$",
        ]
        return any(re.search(pattern, line) for pattern in noise_patterns)

    def _is_noisy_or_mixed_context(self, text: str) -> bool:
        lowered_text = text.lower()
        context_markers = [
            "chatgpt",
            "slack",
            "xcode",
            "google chrome",
            "pycharm",
            "finder",
            "discord",
            "kakaotalk",
            "terminal",
            "safari",
        ]
        marker_count = sum(1 for marker in context_markers if marker in lowered_text)
        noise_count = sum(1 for line in text.splitlines() if self._is_noise_line(line))
        return marker_count >= 4 or noise_count >= 3

    def _limit_text(self, text: str, limit: int) -> str:
        if len(text) <= limit:
            return text
        limited_lines = []
        total_length = 0
        for line in text.splitlines():
            next_length = total_length + len(line) + (1 if limited_lines else 0)
            if next_length > limit:
                break
            limited_lines.append(line)
            total_length = next_length
        return "\n".join(limited_lines)

    def _single_line(self, text: str) -> str:
        return " ".join(text.split())


def get_screen_observation_summarizer() -> ScreenObservationSummarizer:
    return ScreenObservationSummarizer(
        client=GeminiClient(
            api_key=settings.gemini_api_key,
            model=settings.gemini_model,
            max_output_tokens=512,
        ),
        privacy_filter=get_privacy_filter(),
    )
