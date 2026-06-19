from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from app.core.config import Settings


class AIProvider(StrEnum):
    GEMINI = "gemini"
    OPENAI = "openai"


@dataclass(frozen=True)
class AIProviderConfig:
    provider: AIProvider
    api_key: str | None
    model: str

    @property
    def is_configured(self) -> bool:
        return bool(self.api_key)


def resolve_ai_provider_config(settings: Settings) -> AIProviderConfig:
    provider = _resolve_provider(settings)
    if provider == AIProvider.OPENAI:
        return AIProviderConfig(
            provider=provider,
            api_key=settings.openai_api_key,
            model=settings.ai_model or settings.openai_model,
        )

    return AIProviderConfig(
        provider=AIProvider.GEMINI,
        api_key=settings.gemini_api_key,
        model=settings.ai_model or settings.gemini_model,
    )


def _resolve_provider(settings: Settings) -> AIProvider:
    configured = (settings.ai_provider or "").strip().lower()
    if configured == AIProvider.OPENAI.value:
        return AIProvider.OPENAI
    if configured == AIProvider.GEMINI.value:
        return AIProvider.GEMINI
    if settings.openai_api_key and not settings.gemini_api_key:
        return AIProvider.OPENAI
    return AIProvider.GEMINI
