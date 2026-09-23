"""Configuration de l'application, chargee depuis l'environnement / .env."""

from __future__ import annotations

from functools import lru_cache

from pydantic import ValidationError, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# Valeurs d'exemple qui trainent dans .env.example et dans la documentation :
# acceptables en dev, jamais ailleurs.
_PLACEHOLDER_SECRETS = {"change-me", "changeme", "secret", "votre-cle-secrete"}


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
    # Pas de valeur par defaut : sans SECRET_KEY dans l'environnement, le
    # serveur refuse de demarrer. Un defaut connu publiquement rendrait tous
    # les jetons JWT forgeables par quiconque a lu le depot -- une panne au
    # demarrage est infiniment moins couteuse.
    secret_key: str
    algorithm: str = "HS256"
    access_token_expire_minutes: int = 60
    # Glissant : chaque rafraichissement repart pour 30 jours, une tablette en
    # service ne redemande donc jamais le mot de passe.
    refresh_token_expire_days: int = 30
    # Fenetre pendant laquelle un jeton qui vient d'etre echange reste
    # acceptable : la reponse du premier echange a pu se perdre (Wi-Fi), la
    # tablette renvoie alors l'ancien jeton. Au-dela, c'est une reutilisation
    # suspecte et toute la session de l'appareil est revoquee.
    refresh_reuse_grace_seconds: int = 60

    # --- CORS ---
    # Necessaire uniquement pour developper l'application Flutter dans un
    # navigateur : la page est servie sur un port et l'API sur un autre, donc
    # deux origines differentes du point de vue du navigateur. Sur une
    # tablette Android, la cible reelle, CORS n'existe pas.
    #
    # Liste separee par des virgules. En dev, `*` par defaut ; hors dev, la
    # valeur doit etre donnee explicitement -- une API ouverte a tous les
    # sites n'a rien a faire en production.
    cors_origins: str = "*"

    @property
    def cors_origin_list(self) -> list[str]:
        if self.env != "dev" and self.cors_origins.strip() == "*":
            return []
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

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

    @field_validator("secret_key")
    @classmethod
    def _secret_key_solide(cls, v: str, info) -> str:
        """Refuse une cle d'exemple ou trop courte hors developpement.

        Le controle depend de `env`, declare avant `secret_key` dans la
        classe : pydantic valide les champs dans l'ordre de declaration, donc
        `info.data` contient deja `env` ici.
        """
        if info.data.get("env", "dev") == "dev":
            return v
        if v.strip().lower() in _PLACEHOLDER_SECRETS:
            raise ValueError(
                "SECRET_KEY est une valeur d'exemple. Generer une vraie cle : "
                "python -c \"import secrets; print(secrets.token_urlsafe(48))\""
            )
        if len(v) < 32:
            raise ValueError("SECRET_KEY doit faire au moins 32 caracteres hors dev.")
        return v


class ConfigurationManquante(RuntimeError):
    """Configuration absente ou invalide : le serveur ne peut pas demarrer."""


@lru_cache
def get_settings() -> Settings:
    """Charge la configuration, ou echoue avec un message exploitable.

    Sans ce garde-fou, l'oubli d'un `.env` produit une `ValidationError`
    pydantic au milieu d'une pile d'imports -- exact, mais illisible pour qui
    decouvre le projet. On prefere dire quoi faire.
    """
    try:
        return Settings()
    except ValidationError as erreur:
        manquants = [
            ".".join(str(p) for p in detail["loc"])
            for detail in erreur.errors()
            if detail["type"] == "missing"
        ]
        if manquants:
            aide = "\n".join(
                [
                    "Configuration incomplete : "
                    + ", ".join(champ.upper() for champ in manquants)
                    + ".",
                    "Creer le fichier backend/.env :",
                    "    cp .env.example .env",
                    "puis generer une cle :",
                    '    python -c "import secrets; print(secrets.token_urlsafe(48))"',
                ]
            )
            raise ConfigurationManquante(aide) from erreur
        raise ConfigurationManquante(str(erreur)) from erreur


settings = get_settings()
