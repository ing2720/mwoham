"""add dev events

Revision ID: 53f17c2f0c4d
Revises: 3a6a5d2b8c10
Create Date: 2026-06-01 00:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "53f17c2f0c4d"
down_revision: str | None = "3a6a5d2b8c10"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "dev_events",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("session_id", sa.Integer(), nullable=True),
        sa.Column("event_type", sa.String(length=30), nullable=False),
        sa.Column("source", sa.String(length=30), nullable=False),
        sa.Column("repo_path", sa.String(length=500), nullable=True),
        sa.Column("branch", sa.String(length=200), nullable=True),
        sa.Column("command", sa.Text(), nullable=True),
        sa.Column("status", sa.String(length=30), nullable=True),
        sa.Column("summary", sa.Text(), nullable=False),
        sa.Column("details_json", sa.JSON(), nullable=True),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["session_id"], ["work_sessions.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_dev_events_event_type"), "dev_events", ["event_type"], unique=False)
    op.create_index(op.f("ix_dev_events_id"), "dev_events", ["id"], unique=False)
    op.create_index(op.f("ix_dev_events_occurred_at"), "dev_events", ["occurred_at"], unique=False)
    op.create_index(op.f("ix_dev_events_session_id"), "dev_events", ["session_id"], unique=False)
    op.create_index(op.f("ix_dev_events_source"), "dev_events", ["source"], unique=False)
    op.create_index(op.f("ix_dev_events_status"), "dev_events", ["status"], unique=False)


def downgrade() -> None:
    op.drop_index(op.f("ix_dev_events_status"), table_name="dev_events")
    op.drop_index(op.f("ix_dev_events_source"), table_name="dev_events")
    op.drop_index(op.f("ix_dev_events_session_id"), table_name="dev_events")
    op.drop_index(op.f("ix_dev_events_occurred_at"), table_name="dev_events")
    op.drop_index(op.f("ix_dev_events_id"), table_name="dev_events")
    op.drop_index(op.f("ix_dev_events_event_type"), table_name="dev_events")
    op.drop_table("dev_events")
