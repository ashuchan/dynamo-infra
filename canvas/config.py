from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field, computed_field
from pathlib import Path


class CanvasSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="CANVAS_")

    # ── Database ──────────────────────────────────────────────────────────────
    db_host: str = Field(
        default="localhost",
        description="Canvas DB host or Unix socket path (/cloudsql/... in Cloud Run).",
    )
    db_name: str = Field(default="canvas")
    db_user: str = Field(default="canvas_app")
    db_password: str = Field(default="", repr=False)
    db_port: int = Field(default=5432)

    @computed_field  # type: ignore[misc]
    @property
    def database_url(self) -> str:
        """
        Async URL for the FastAPI runtime (asyncpg).
        Unix socket: postgresql+asyncpg://user:pass@/dbname?host=/cloudsql/...
        TCP:         postgresql+asyncpg://user:pass@host:port/dbname
        """
        if self.db_host.startswith("/"):
            # Cloud SQL Auth Proxy via Unix domain socket
            return (
                f"postgresql+asyncpg://{self.db_user}:{self.db_password}"
                f"@/{self.db_name}?host={self.db_host}"
            )
        return (
            f"postgresql+asyncpg://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )

    # ── Output directory (GCS mount in Cloud Run, local path in dev) ──────────
    output_dir: Path = Field(
        default=Path("canvas-output"),
        description=(
            "Path where Canvas writes generated files. "
            "In Cloud Run this is /app/canvas-output (GCS bucket mount). "
            "In local dev this defaults to ./canvas-output."
        ),
    )

    # ── Session ───────────────────────────────────────────────────────────────
    session_ttl_hours: int = Field(
        default=24,
        description="Hours after which an inactive canvas session is marked abandoned.",
    )

    # ── Resync flag (read-only at runtime — only used by migrate job) ─────────
    db_resync: bool = Field(
        default=False,
        description="Internal flag. Read by migrate_entrypoint.sh only — not consumed by FastAPI.",
    )


# Module-level singleton — import this everywhere in the canvas package
canvas_settings = CanvasSettings()
