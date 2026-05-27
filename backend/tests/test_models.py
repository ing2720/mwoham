from app.models import Base


def test_initial_worklog_tables_are_registered() -> None:
    assert {
        "projects",
        "app_settings",
        "work_sessions",
        "work_events",
        "manual_memos",
        "meeting_sessions",
        "private_apps",
        "reports",
        "screen_observations",
        "voice_transcripts",
    }.issubset(Base.metadata.tables)


def test_initial_model_foreign_keys() -> None:
    work_sessions = Base.metadata.tables["work_sessions"]
    work_events = Base.metadata.tables["work_events"]
    manual_memos = Base.metadata.tables["manual_memos"]
    reports = Base.metadata.tables["reports"]
    screen_observations = Base.metadata.tables["screen_observations"]
    meeting_sessions = Base.metadata.tables["meeting_sessions"]
    voice_transcripts = Base.metadata.tables["voice_transcripts"]

    assert next(iter(work_sessions.c.project_id.foreign_keys)).ondelete == "SET NULL"
    assert next(iter(work_events.c.session_id.foreign_keys)).ondelete == "CASCADE"
    assert next(iter(manual_memos.c.session_id.foreign_keys)).ondelete == "SET NULL"
    assert next(iter(reports.c.project_id.foreign_keys)).ondelete == "SET NULL"
    assert next(iter(screen_observations.c.session_id.foreign_keys)).ondelete == "CASCADE"
    assert next(iter(meeting_sessions.c.session_id.foreign_keys)).ondelete == "CASCADE"
    assert next(iter(voice_transcripts.c.meeting_id.foreign_keys)).ondelete == "CASCADE"
