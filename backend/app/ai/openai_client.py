import logging
from typing import Any

import httpx

from app.ai.text_generation import TextGenerationResult

logger = logging.getLogger(__name__)


class OpenAIClient:
    def __init__(
        self,
        *,
        api_key: str | None,
        model: str,
        max_output_tokens: int = 8192,
        timeout_seconds: float = 30.0,
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

    def generate_text_result(self, prompt: str) -> TextGenerationResult:
        if not self.api_key:
            return self._empty_result(error_reason="api_key_missing")

        payload = {
            "model": self.model,
            "input": prompt,
            "max_output_tokens": self.max_output_tokens,
        }

        try:
            response = httpx.post(
                "https://api.openai.com/v1/responses",
                headers={
                    "Authorization": f"Bearer {self.api_key}",
                    "Content-Type": "application/json",
                },
                json=payload,
                timeout=self.timeout_seconds,
            )
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raw_error = self._safe_response_text(exc.response)
            return self._empty_result(
                error_reason=self._http_error_reason(exc.response),
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
                TextGenerationResult(
                    text=None,
                    finish_reason=result.finish_reason,
                    error_reason=result.error_reason or "text_missing",
                    status_code=response.status_code,
                    raw_error=result.raw_error,
                )
            )
        return result

    def _extract_result(self, payload: dict[str, Any]) -> TextGenerationResult:
        output_text = payload.get("output_text")
        if isinstance(output_text, str) and output_text.strip():
            return TextGenerationResult(
                text=output_text.strip(),
                finish_reason=self._finish_reason(payload),
            )

        output = payload.get("output") or []
        text_parts: list[str] = []
        if isinstance(output, list):
            for item in output:
                if not isinstance(item, dict):
                    continue
                content = item.get("content") or []
                if not isinstance(content, list):
                    continue
                for content_item in content:
                    if not isinstance(content_item, dict):
                        continue
                    text = content_item.get("text")
                    if isinstance(text, str) and text.strip():
                        text_parts.append(text.strip())

        text = "\n".join(text_parts).strip()
        if not text:
            return TextGenerationResult(
                text=None,
                finish_reason=self._finish_reason(payload),
                error_reason="text_missing",
            )
        return TextGenerationResult(text=text, finish_reason=self._finish_reason(payload))

    def _finish_reason(self, payload: dict[str, Any]) -> str | None:
        status = payload.get("status")
        if isinstance(status, str) and status != "completed":
            return status
        incomplete_details = payload.get("incomplete_details")
        if isinstance(incomplete_details, dict):
            reason = incomplete_details.get("reason")
            if isinstance(reason, str):
                return reason
        return status if isinstance(status, str) else None

    def _empty_result(
        self,
        *,
        error_reason: str,
        status_code: int | None = None,
        raw_error: str | None = None,
    ) -> TextGenerationResult:
        return self._log_empty_result(
            TextGenerationResult(
                text=None,
                error_reason=error_reason,
                status_code=status_code,
                raw_error=raw_error,
            )
        )

    def _log_empty_result(self, result: TextGenerationResult) -> TextGenerationResult:
        logger.warning(
            "OpenAI generate_text returned empty: reason=%s model=%s status_code=%s "
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

    def _http_error_reason(self, response: httpx.Response) -> str:
        if response.status_code in {401, 403}:
            return "invalid_api_key"
        if response.status_code == 429:
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
