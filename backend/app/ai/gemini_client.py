import logging
from typing import Any

import httpx

from app.ai.text_generation import TextGenerationResult

logger = logging.getLogger(__name__)


GeminiTextResult = TextGenerationResult


class GeminiClient:
    def __init__(
        self,
        *,
        api_key: str | None,
        model: str,
        max_output_tokens: int = 8192,
        timeout_seconds: float = 20.0,
    ) -> None:
        self.api_key = api_key
        self.model = model
        self.max_output_tokens = max_output_tokens
        self.timeout_seconds = timeout_seconds

    @property
    def is_configured(self) -> bool:
        return bool(self.api_key)

    def generate_text(self, prompt: str) -> str | None:
        return self.generate_text_result(prompt).text

    def generate_text_result(self, prompt: str) -> GeminiTextResult:
        if not self.api_key:
            return self._empty_result(error_reason="api_key_missing")

        url = (
            f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent"
        )
        payload = {
            "contents": [
                {
                    "role": "user",
                    "parts": [{"text": prompt}],
                }
            ],
            "generationConfig": {
                "temperature": 0.2,
                "maxOutputTokens": self.max_output_tokens,
            },
        }

        try:
            response = httpx.post(
                url,
                headers={"x-goog-api-key": self.api_key},
                json=payload,
                timeout=self.timeout_seconds,
            )
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raw_error = self._safe_response_text(exc.response)
            return self._empty_result(
                error_reason=self._http_error_reason(exc.response, raw_error),
                status_code=exc.response.status_code,
                raw_error=raw_error,
            )
        except httpx.TimeoutException as exc:
            return self._empty_result(error_reason="timeout", raw_error=str(exc))
        except httpx.HTTPError as exc:
            return self._empty_result(error_reason="network_error", raw_error=str(exc))

        try:
            payload = response.json()
        except ValueError as exc:
            return self._empty_result(
                error_reason="json_parse_error",
                status_code=response.status_code,
                raw_error=str(exc),
            )

        result = self._extract_result(payload)
        if result.text is None:
            return self._log_empty_result(
                GeminiTextResult(
                    text=None,
                    finish_reason=result.finish_reason,
                    error_reason=result.error_reason or "text_missing",
                    status_code=response.status_code,
                    raw_error=result.raw_error,
                )
            )
        if result.finish_reason and result.finish_reason != "STOP":
            logger.warning(
                "Gemini response finishReason is not STOP: reason=%s model=%s finish_reason=%s",
                result.error_reason or "non_stop_finish_reason",
                self.model,
                result.finish_reason,
            )

        return result

    def _extract_text(self, payload: dict[str, Any]) -> str | None:
        return self._extract_result(payload).text

    def _extract_result(self, payload: dict[str, Any]) -> GeminiTextResult:
        prompt_feedback = payload.get("promptFeedback") or {}
        block_reason = prompt_feedback.get("blockReason")
        if block_reason:
            return GeminiTextResult(
                text=None,
                error_reason="safety_block",
                raw_error=f"blockReason={block_reason}",
            )

        candidates = payload.get("candidates") or []
        if not candidates:
            return GeminiTextResult(text=None, error_reason="candidates_missing")
        candidate = candidates[0]
        finish_reason = candidate.get("finishReason")
        if finish_reason and finish_reason != "STOP":
            error_reason = "non_stop_finish_reason"
            if finish_reason in {"SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST"}:
                error_reason = "safety_block"
        else:
            error_reason = None

        content = candidate.get("content")
        if not isinstance(content, dict):
            return GeminiTextResult(
                text=None,
                finish_reason=finish_reason,
                error_reason="content_missing",
            )

        parts = content.get("parts") or []
        if not parts:
            return GeminiTextResult(
                text=None,
                finish_reason=finish_reason,
                error_reason="parts_missing",
            )

        text_parts = [part.get("text", "") for part in parts if part.get("text")]
        text = "\n".join(text_parts).strip()
        if not text:
            return GeminiTextResult(
                text=None,
                finish_reason=finish_reason,
                error_reason="text_missing",
            )
        return GeminiTextResult(text=text, finish_reason=finish_reason, error_reason=error_reason)

    def _empty_result(
        self,
        *,
        error_reason: str,
        status_code: int | None = None,
        raw_error: str | None = None,
    ) -> GeminiTextResult:
        return self._log_empty_result(
            GeminiTextResult(
                text=None,
                error_reason=error_reason,
                status_code=status_code,
                raw_error=raw_error,
            )
        )

    def _log_empty_result(self, result: GeminiTextResult) -> GeminiTextResult:
        logger.warning(
            "Gemini generate_text returned empty: reason=%s model=%s status_code=%s "
            "finish_reason=%s raw_error=%s",
            result.error_reason,
            self.model,
            result.status_code,
            result.finish_reason,
            self._truncate_log_value(result.raw_error),
        )
        return result

    def _safe_response_text(self, response: httpx.Response) -> str:
        try:
            return response.text
        except RuntimeError:
            return "<response body unavailable>"

    def _http_error_reason(self, response: httpx.Response, raw_error: str) -> str:
        if response.status_code in {401, 403}:
            return "invalid_api_key"
        if response.status_code == 429 or "RESOURCE_EXHAUSTED" in raw_error:
            return "quota_exceeded"
        return "http_status_error"

    def _truncate_log_value(self, value: str | None, limit: int = 500) -> str | None:
        if value is None:
            return None
        if self.api_key:
            value = value.replace(self.api_key, "<redacted-api-key>")
        if len(value) <= limit:
            return value
        return value[:limit] + "...<truncated>"
