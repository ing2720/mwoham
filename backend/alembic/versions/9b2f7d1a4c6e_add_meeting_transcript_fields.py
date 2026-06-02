"""add meeting transcript fields

Revision ID: 9b2f7d1a4c6e
Revises: 53f17c2f0c4d
Create Date: 2026-06-02 16:15:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "9b2f7d1a4c6e"
down_revision: str | None = "53f17c2f0c4d"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("voice_transcripts") as batch_op:
        batch_op.alter_column(
            "meeting_id",
            existing_type=sa.Integer(),
            nullable=True,
        )
        batch_op.add_column(
            sa.Column(
                "source",
                sa.String(length=50),
                server_default="apple_speech",
                nullable=False,
            )
        )
        batch_op.add_column(sa.Column("started_at", sa.DateTime(timezone=True), nullable=True))
        batch_op.add_column(sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True))
        batch_op.create_index(
            op.f("ix_voice_transcripts_started_at"),
            ["started_at"],
            unique=False,
        )
        batch_op.create_index(
            op.f("ix_voice_transcripts_ended_at"),
            ["ended_at"],
            unique=False,
        )


def downgrade() -> None:
    with op.batch_alter_table("voice_transcripts") as batch_op:
        batch_op.drop_index(op.f("ix_voice_transcripts_ended_at"))
        batch_op.drop_index(op.f("ix_voice_transcripts_started_at"))
        batch_op.drop_column("ended_at")
        batch_op.drop_column("started_at")
        batch_op.drop_column("source")
        batch_op.alter_column(
            "meeting_id",
            existing_type=sa.Integer(),
            nullable=False,
        )
