"""canvas initial schema

Revision ID: 0001
Revises:
Create Date: 2025-01-01 00:00:00.000000
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB, UUID
import uuid

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    # ── canvas_sessions ───────────────────────────────────────────────────────
    # One row per Canvas operator session. Tracks lifecycle from created → complete.
    op.create_table(
        "canvas_sessions",
        sa.Column("session_id",   UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("operator_id",  sa.String(255), nullable=False),
        sa.Column("domain_hint",  sa.Text,        nullable=True),   # e.g. "HR management system"
        sa.Column("state",        sa.String(50),  nullable=False, server_default="active"),
                                                                     # active | complete | abandoned
        sa.Column("created_at",   sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_canvas_sessions_operator_id", "canvas_sessions", ["operator_id"])
    op.create_index("ix_canvas_sessions_state",       "canvas_sessions", ["state"])

    # ── canvas_turns ──────────────────────────────────────────────────────────
    # Ordered conversation turns within a session.
    op.create_table(
        "canvas_turns",
        sa.Column("turn_id",       UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("session_id",    UUID(as_uuid=True),
                  sa.ForeignKey("canvas_sessions.session_id", ondelete="CASCADE"), nullable=False),
        sa.Column("role",          sa.String(20),  nullable=False),  # user | assistant
        sa.Column("message",       sa.Text,        nullable=False),
        sa.Column("intent_parsed", JSONB,          nullable=True),   # structured intent extracted from user turn
        sa.Column("created_at",    sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_canvas_turns_session_id",  "canvas_turns", ["session_id"])
    op.create_index("ix_canvas_turns_created_at",  "canvas_turns", ["created_at"])

    # ── canvas_themes ─────────────────────────────────────────────────────────
    # Generated theme CSS output per session. Validated before persistence.
    op.create_table(
        "canvas_themes",
        sa.Column("theme_id",       UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("session_id",     UUID(as_uuid=True),
                  sa.ForeignKey("canvas_sessions.session_id", ondelete="CASCADE"), nullable=False),
        sa.Column("name",           sa.String(255), nullable=False),
        sa.Column("aesthetic_mood", sa.String(50),  nullable=True),   # AestheticMood enum value
        sa.Column("css_content",    sa.Text,        nullable=False),   # full CSS file content
        sa.Column("validated",      sa.Boolean,     nullable=False, server_default="false"),
        sa.Column("created_at",     sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_canvas_themes_session_id", "canvas_themes", ["session_id"])

    # ── canvas_layouts ────────────────────────────────────────────────────────
    # Generated layout.config.yaml content per session.
    op.create_table(
        "canvas_layouts",
        sa.Column("layout_id",   UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("session_id",  UUID(as_uuid=True),
                  sa.ForeignKey("canvas_sessions.session_id", ondelete="CASCADE"), nullable=False),
        sa.Column("archetype",   sa.String(50),  nullable=True),   # layout archetype name
        sa.Column("config_json", JSONB,          nullable=False),   # parsed layout config
        sa.Column("created_at",  sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_canvas_layouts_session_id", "canvas_layouts", ["session_id"])

    # ── canvas_enriched_skills ────────────────────────────────────────────────
    # Enriched *.skill.yaml content produced by SkillEnricher, stored per session.
    op.create_table(
        "canvas_enriched_skills",
        sa.Column("skill_id",     UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("session_id",   UUID(as_uuid=True),
                  sa.ForeignKey("canvas_sessions.session_id", ondelete="CASCADE"), nullable=False),
        sa.Column("entity",       sa.String(255), nullable=False),   # PascalCase entity name
        sa.Column("yaml_content", sa.Text,        nullable=False),   # full enriched YAML
        sa.Column("validated",    sa.Boolean,     nullable=False, server_default="false"),
        sa.Column("created_at",   sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_canvas_enriched_skills_session_id", "canvas_enriched_skills", ["session_id"])
    op.create_index("ix_canvas_enriched_skills_entity",     "canvas_enriched_skills", ["entity"])

    # ── canvas_domain_patterns ────────────────────────────────────────────────
    # Domain-seeded NL patterns produced by DomainPatternSeeder, stored per session.
    op.create_table(
        "canvas_domain_patterns",
        sa.Column("pattern_id",   UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("session_id",   UUID(as_uuid=True),
                  sa.ForeignKey("canvas_sessions.session_id", ondelete="CASCADE"), nullable=False),
        sa.Column("entity",       sa.String(255), nullable=False),
        sa.Column("yaml_content", sa.Text,        nullable=False),
        sa.Column("created_at",   sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_canvas_domain_patterns_session_id", "canvas_domain_patterns", ["session_id"])
    op.create_index("ix_canvas_domain_patterns_entity",     "canvas_domain_patterns", ["entity"])

    # ── canvas_output_files ───────────────────────────────────────────────────
    # Manifest of files committed to canvas-output/ (GCS or local) per session.
    op.create_table(
        "canvas_output_files",
        sa.Column("file_id",     UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("session_id",  UUID(as_uuid=True),
                  sa.ForeignKey("canvas_sessions.session_id", ondelete="CASCADE"), nullable=False),
        sa.Column("file_type",   sa.String(50),  nullable=False),   # theme | skill | pattern | layout | readme
        sa.Column("path",        sa.Text,        nullable=False),   # GCS path or local relative path
        sa.Column("committed",   sa.Boolean,     nullable=False, server_default="false"),
        sa.Column("created_at",  sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_canvas_output_files_session_id", "canvas_output_files", ["session_id"])
    op.create_index("ix_canvas_output_files_file_type",  "canvas_output_files", ["file_type"])


def downgrade() -> None:
    # Drop in reverse FK dependency order
    op.drop_table("canvas_output_files")
    op.drop_table("canvas_domain_patterns")
    op.drop_table("canvas_enriched_skills")
    op.drop_table("canvas_layouts")
    op.drop_table("canvas_themes")
    op.drop_table("canvas_turns")
    op.drop_table("canvas_sessions")
