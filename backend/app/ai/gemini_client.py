from dataclasses import dataclass
from typing import Any

import httpx


@dataclass(frozen=True)
class GeminiTextResult:
    text: str | None
    finish_reason: str | None = None

    @property
    def was_truncated(self) -> bool:
        return self.finish_reason in {"MAX_TOKENS", "STOP_REASON_MAX_TOKENS"}


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
            return GeminiTextResult(text=None)

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
        except httpx.HTTPError:
            return GeminiTextResult(text=None)

        return self._extract_result(response.json())

    def _extract_text(self, payload: dict[str, Any]) -> str | None:
        return self._extract_result(payload).text

    def _extract_result(self, payload: dict[str, Any]) -> GeminiTextResult:
        candidates = payload.get("candidates") or []
        if not candidates:
            return GeminiTextResult(text=None)
        candidate = candidates[0]
        parts = candidate.get("content", {}).get("parts", [])
        text_parts = [part.get("text", "") for part in parts if part.get("text")]
        text = "\n".join(text_parts).strip()
        finish_reason = candidate.get("finishReason")
        return GeminiTextResult(text=text or None, finish_reason=finish_reason)
