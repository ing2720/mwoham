from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "Mwoham Backend"
    app_version: str = "0.1.0"
    app_host: str = "127.0.0.1"
    app_port: int = 8765
    database_url: str = "sqlite:///./data/mwoham.sqlite3"
    gemini_api_key: str | None = None
    gemini_model: str = "gemini-2.5-flash"
    report_export_dir: str = "exports/reports"
    local_api_token: str | None = None

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
