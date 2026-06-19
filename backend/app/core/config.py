from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "Mwoham Backend"
    app_version: str = "0.1.0"
    app_host: str = "127.0.0.1"
    app_port: int = 8765
    database_url: str = "sqlite:///./data/mwoham.sqlite3"
    ai_provider: str | None = None
    ai_model: str | None = None
    gemini_api_key: str | None = None
    gemini_model: str = "gemini-2.5-flash-lite"
    gemini_max_output_tokens: int = 8192
    ai_report_timeout_seconds: float = 25.0
    openai_api_key: str | None = None
    openai_model: str = "gpt-5.2-mini"
    enable_screen_observation_ai_inference: bool = False
    screen_ai_min_interval_seconds: int = 300
    screen_ai_daily_limit: int = 5
    report_export_dir: str = "exports/reports"
    local_api_token: str | None = None

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
