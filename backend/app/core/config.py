"""Configuration de l'application, chargee depuis l'environnement / .env."""

from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )

    # --- Application ---
    app_name: str = "Atrium"
    env: str = "dev"
    api_prefix: str = "/api/v1"
    debug: bool = True

    # --- Securite ---
    secret_key: str = "change-me"
    algorithm: str = "HS256"
    access_token_expire_minutes: int = 60
    refresh_token_expire_days: int = 30

    # --- Base de donnees ---
    database_url: str = "postgresql+asyncpg://atrium:change-me@localhost:5432/atrium"

    @property
    def sync_database_url(self) -> str:
        """URL synchrone, utilisee par Alembic."""
        return self.database_url.replace("+asyncpg", "+psycopg")

    # --- Synchronisation ---
    # Fenetre glissante repliquee sur les tablettes (cf. docs/01-modele-de-donnees.md).
    sync_window_past_days: int = 90
    sync_window_future_days: int = 365
    sync_batch_size: int = 500


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
