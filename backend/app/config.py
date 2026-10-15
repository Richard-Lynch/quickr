from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="QUICKR_", env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://quickr:quickr@localhost:5433/quickr"
    cors_origins: list[str] = ["http://localhost:5180", "http://localhost:8080"]
    db_echo: bool = False

    # Web Push (VAPID). When unset, a key pair is generated once and stored in app_settings.
    vapid_private_key: str | None = None  # base64url raw 32-byte key, or base64url DER
    vapid_public_key: str | None = None  # base64url uncompressed P-256 point
    vapid_subject: str = "mailto:admin@localhost"

    # Background task that sends "topic due" notifications.
    scheduler_enabled: bool = True
    scheduler_interval_seconds: float = 60.0


@lru_cache
def get_settings() -> Settings:
    return Settings()
