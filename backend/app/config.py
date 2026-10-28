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
    # A mailto: or https: URL identifying the sender (Apple rejects mailto:...@localhost).
    vapid_subject: str = "https://github.com/Richard-Lynch/quickr"
    # Extra push service hosts (JSON list) on top of app.push_guard.DEFAULT_PUSH_HOSTS.
    push_allowed_hosts: list[str] = []

    # APNs (the iOS app). Off unless the team id, key id and a key (inline or file) are all set.
    apns_team_id: str | None = None
    apns_key_id: str | None = None
    # The .p8 key: PEM text (literal "\n" escapes allowed) or a path to the file.
    apns_private_key: str | None = None
    apns_private_key_file: str | None = None
    apns_topic: str = "com.bahumia.quickr"  # the app's bundle id
    # Optional separate key for the sandbox host (Apple keys can be limited to one environment).
    apns_sandbox_key_id: str | None = None
    apns_sandbox_private_key: str | None = None
    apns_sandbox_private_key_file: str | None = None

    # Client levels (docs/specs/client-versions.md §2): an emergency raise of a platform's
    # minimum, without a release. Clamped to the server's api_level.
    min_client_level_ios: int | None = None
    min_client_level_web: int | None = None
    # Where the iOS "Update required" screen sends the user (itms-beta:// opens TestFlight).
    ios_update_url: str = "itms-beta://"

    # Background task that sends "topic due" notifications.
    scheduler_enabled: bool = True
    scheduler_interval_seconds: float = 60.0


@lru_cache
def get_settings() -> Settings:
    return Settings()
