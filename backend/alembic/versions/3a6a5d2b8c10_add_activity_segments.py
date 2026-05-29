"""add activity segments

Revision ID: 3a6a5d2b8c10
Revises: a3e489b00017
Create Date: 2026-05-29 14:05:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "3a6a5d2b8c10"
down_revision: str | None = "a3e489b00017"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "activity_segments",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("session_id", sa.Integer(), nullable=False),
        sa.Column("app_name", sa.String(length=100), nullable=True),
        sa.Column("window_title", sa.String(length=255), nullable=True),
        sa.Column("source", sa.String(length=30), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("duration_seconds", sa.Integer(), server_default="0", nullable=False),
        sa.Column("sample_count", sa.Integer(), server_default="1", nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["session_id"], ["work_sessions.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_activity_segments_app_name"), "activity_segments", ["app_name"])
    op.create_index(op.f("ix_activity_segments_ended_at"), "activity_segments", ["ended_at"])
    op.create_index(op.f("ix_activity_segments_id"), "activity_segments", ["id"])
    op.create_index(
        op.f("ix_activity_segments_last_seen_at"),
        "activity_segments",
        ["last_seen_at"],
    )
    op.create_index(
        op.f("ix_activity_segments_session_id"),
        "activity_segments",
        ["session_id"],
    )
    op.create_index(op.f("ix_activity_segments_source"), "activity_segments", ["source"])
    op.create_index(
        op.f("ix_activity_segments_started_at"),
        "activity_segments",
        ["started_at"],
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_activity_segments_started_at"), table_name="activity_segments")
    op.drop_index(op.f("ix_activity_segments_source"), table_name="activity_segments")
    op.drop_index(op.f("ix_activity_segments_session_id"), table_name="activity_segments")
    op.drop_index(op.f("ix_activity_segments_last_seen_at"), table_name="activity_segments")
    op.drop_index(op.f("ix_activity_segments_id"), table_name="activity_segments")
    op.drop_index(op.f("ix_activity_segments_ended_at"), table_name="activity_segments")
    op.drop_index(op.f("ix_activity_segments_app_name"), table_name="activity_segments")
    op.drop_table("activity_segments")
