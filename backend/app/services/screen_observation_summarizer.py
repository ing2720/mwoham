from app.ai.gemini_client import GeminiClient
from app.core.config import settings
from app.services.privacy_filter import PrivacyFilter, get_privacy_filter


class ScreenObservationSummarizer:
    def __init__(
        self,
        *,
        client: GeminiClient,
        privacy_filter: PrivacyFilter,
        minimum_text_length: int = 20,
        max_ocr_text_length: int = 3000,
        max_inference_length: int = 300,
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
            return None

        prompt = self._build_prompt(
            ocr_text=cleaned_ocr_text[: self.max_ocr_text_length],
            app_name=app_name,
            window_title=window_title,
        )
        if self.client.is_configured:
            inference = self.client.generate_text(prompt)
            if inference:
                return self._clean_inference(inference)

        return self._fallback_inference(
            ocr_text=cleaned_ocr_text,
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
                "사용자가 지금 어떤 작업을 하고 있는지 1~2문장의 한국어로 추론하세요.",
                "확실하지 않은 내용은 단정하지 말고 관찰된 텍스트 기준으로 표현하세요.",
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
        ocr_text: str,
        app_name: str | None,
        window_title: str | None,
    ) -> str:
        context_parts = [part for part in [app_name, window_title] if part]
        context = " / ".join(context_parts)
        excerpt = self._single_line(ocr_text)[:80]
        if context:
            return f"{context} 화면에서 '{excerpt}' 관련 작업을 확인하고 있습니다."
        return f"화면에서 '{excerpt}' 관련 작업을 확인하고 있습니다."

    def _clean_text(self, text: str | None) -> str:
        if not text:
            return ""
        return "\n".join(line.strip() for line in text.splitlines() if line.strip())

    def _has_enough_text(self, text: str) -> bool:
        meaningful_count = sum(1 for character in text if character.isalnum())
        return meaningful_count >= self.minimum_text_length

    def _clean_inference(self, inference: str) -> str | None:
        cleaned = self._single_line(inference)
        if not cleaned:
            return None
        return cleaned[: self.max_inference_length]

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
