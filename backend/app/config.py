from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="QUICKER_", env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://quicker:quicker@localhost:5433/quicker"
    cors_origins: list[str] = ["http://localhost:5180", "http://localhost:8080"]
    db_echo: bool = False


@lru_cache
def get_settings() -> Settings:
    return Settings()
