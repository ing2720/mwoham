from dataclasses import dataclass


@dataclass(frozen=True)
class TextGenerationResult:
    text: str | None
    finish_reason: str | None = None
    error_reason: str | None = None
    status_code: int | None = None
    raw_error: str | None = None

    @property
    def was_truncated(self) -> bool:
        return self.finish_reason in {
            "MAX_TOKENS",
            "STOP_REASON_MAX_TOKENS",
            "length",
            "max_output_tokens",
            "incomplete",
        }
