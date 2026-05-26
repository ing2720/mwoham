from app.models import Base


def test_initial_worklog_tables_are_registered() -> None:
    assert {
        "projects",
        "work_sessions",
        "work_events",
        "manual_memos",
    }.issubset(Base.metadata.tables)


def test_initial_model_foreign_keys() -> None:
    work_sessions = Base.metadata.tables["work_sessions"]
    work_events = Base.metadata.tables["work_events"]
    manual_memos = Base.metadata.tables["manual_memos"]

    assert next(iter(work_sessions.c.project_id.foreign_keys)).ondelete == "SET NULL"
    assert next(iter(work_events.c.session_id.foreign_keys)).ondelete == "CASCADE"
    assert next(iter(manual_memos.c.session_id.foreign_keys)).ondelete == "SET NULL"
