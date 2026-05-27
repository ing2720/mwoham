# PROJECT_CONTEXT.md

## 1. Project Overview

This project is a personal macOS AI work-understanding agent.

The app observes a user's local work activity on macOS, collects work-related signals, organizes them into a timeline, and generates daily work reports, troubleshooting notes, and portfolio-ready snippets using Gemini.

The project is not a cloud SaaS product in its initial scope. It is a local-first personal productivity tool.

## 2. Core Concept

The goal is to build a local macOS agent that can answer questions like:

- What did I work on today?
- What problem did I run into?
- How did I solve it?
- What was discussed during a meeting?
- What useful portfolio material can be generated from my work history?

The system should collect work context from:

- Active application name
- Window title
- Browser/document context
- Screen OCR text
- Git/terminal events
- Meeting session metadata
- Voice transcripts
- Manual quick memos

The system should then merge these signals into a chronological timeline and use AI to generate:

- Daily reports
- Simple summary reports
- Troubleshooting reports
- Portfolio snippets

## 3. Product Direction

This project is not just a time tracker.

It should not only record how long an app was used. It should infer the user's work flow from multiple signals and turn that into useful written outputs.

Important positioning:

- Not an employee monitoring tool
- Not a cloud surveillance system
- Not a full screen recording archive
- A personal local assistant for work recall, troubleshooting, and portfolio writing

## 4. Target User

Initial target user:

- One person
- macOS user
- Developer/PM/mentor type workflow
- Wants to remember what they worked on
- Wants to use work history later for portfolio/resume material

Initial scope does not include:

- Team management
- Admin dashboard
- Multi-user accounts
- Cloud sync
- Windows support
- Mobile app

## 5. High-Level Architecture

The system is split into three main parts.

```text
Swift macOS App
→ Python Local Backend
→ SQLite

Local Web Dashboard
→ Python Local Backend
→ SQLite
```

### Swift macOS App

Responsible for macOS-native behavior:

- Floating widget
- Menu bar app
- Settings window
- Screen capture permission
- Microphone/audio permission
- Active app/window detection
- Screen frame capture
- OCR integration
- Meeting mode controls
- Local API calls to Python backend

### Python Local Backend

Responsible for the core service logic:

- FastAPI local API
- SQLite persistence
- Recording status management
- Event storage
- Timeline building
- Privacy filtering
- Gemini API calls
- Report generation
- Portfolio snippet generation
- Markdown/PDF export
- Local web dashboard

### Local Web Dashboard

Responsible for larger review/editing workflows:

- Today dashboard
- Timeline review
- Report generation
- Report editing
- Troubleshooting report view
- Portfolio snippet management
- Project management
- Settings
- Private app management

## 6. Technology Stack

### Client

- Swift
- SwiftUI
- AppKit
- ScreenCaptureKit
- Vision
- Speech
- AVFoundation
- URLSession
- Xcode

### Backend

- Python
- FastAPI
- Uvicorn
- Pydantic
- SQLAlchemy
- Alembic
- SQLite
- httpx
- Gemini API
- pytest
- ruff
- uv

### Dashboard

Initial recommendation:

- FastAPI Templates
- Jinja2
- HTMX
- Basic CSS or Tailwind CSS

React is not required for the initial local dashboard.

### Report

- Markdown first
- HTML preview second
- PDF export later
- Candidate libraries: WeasyPrint or ReportLab

### Packaging

- Xcode for macOS app build
- PyInstaller for bundling Python backend
- `.app` for personal use
- `.dmg` for sharing
- Code signing/notarization only when needed for external distribution

## 7. Repository Structure

Recommended repository name:

```text
mwoham
```

Recommended structure:

```text
mwoham/
  backend/
  mac-client/
  docs/
```

Expected backend structure:

```text
backend/
  pyproject.toml
  uv.lock
  README.md
  .env.example

  app/
    main.py

    api/
      router.py
      endpoints/
        health.py
        status.py
        recording.py
        projects.py
        events.py
        screen_observations.py
        memos.py
        meetings.py
        transcripts.py
        timeline.py
        reports.py
        settings.py

    core/
      config.py
      security.py
      constants.py
      exceptions.py

    db/
      session.py
      base.py
      init_db.py

    models/
      project.py
      work_session.py
      work_event.py
      screen_observation.py
      meeting_session.py
      voice_transcript.py
      manual_memo.py
      timeline_block.py
      report.py
      portfolio_snippet.py
      app_setting.py
      private_app.py

    schemas/
      common.py
      status.py
      recording.py
      project.py
      work_event.py
      screen_observation.py
      meeting.py
      transcript.py
      memo.py
      timeline.py
      report.py
      setting.py

    repositories/
      project_repository.py
      work_session_repository.py
      work_event_repository.py
      screen_observation_repository.py
      meeting_repository.py
      memo_repository.py
      timeline_repository.py
      report_repository.py
      setting_repository.py

    services/
      recording_service.py
      event_service.py
      meeting_service.py
      timeline_builder.py
      report_service.py
      portfolio_service.py
      setting_service.py
      privacy_filter.py

    ai/
      gemini_client.py
      prompt_builder.py
      summarizer.py
      troubleshooting_extractor.py
      portfolio_generator.py

    report/
      markdown_generator.py
      pdf_generator.py
      export_service.py

    web/
      routes.py
      templates/
      static/

  alembic/
    versions/
  alembic.ini

  tests/
```

## 8. Core Data Model

The ERD is based on this flow:

```text
Project
→ WorkSession
→ WorkEvent / ScreenObservation / MeetingSession / ManualMemo
→ TimelineBlock
→ Report
→ PortfolioSnippet
```

Core tables:

- projects
- work_sessions
- work_events
- screen_observations
- meeting_sessions
- voice_transcripts
- manual_memos
- timeline_blocks
- timeline_block_events
- reports
- report_timeline_blocks
- portfolio_snippets
- app_settings
- private_apps

Important design notes:

- WorkSession represents recording start to stop.
- WorkEvent stores app/window/browser/Git/terminal events.
- ScreenObservation stores OCR/vision analysis text only, not raw screenshots.
- MeetingSession stores meeting periods.
- VoiceTranscript stores text transcript only, not raw audio.
- ManualMemo stores user-provided context.
- TimelineBlock is an intermediate compressed work unit before AI reporting.
- Report stores generated or user-edited reports.
- PortfolioSnippet stores portfolio-ready sentences.

## 9. API Domains

The local API is served by FastAPI at:

```text
http://127.0.0.1:8765
```

Do not expose it on `0.0.0.0` in the initial version.

Main API groups:

### Health and Status

- GET /health
- GET /status

### Recording

- POST /recording/start
- POST /recording/pause
- POST /recording/resume
- POST /recording/stop

### Projects

- POST /projects
- GET /projects
- GET /projects/{project_id}
- PATCH /projects/{project_id}
- DELETE /projects/{project_id}

### Events

- POST /events
- GET /events
- POST /screen-observations
- GET /timeline/today

### Memos

- POST /memos
- GET /memos
- PATCH /memos/{memo_id}
- DELETE /memos/{memo_id}

### Meetings

- POST /meetings/start
- POST /meetings/{meeting_id}/end
- GET /meetings
- POST /transcripts
- GET /meetings/{meeting_id}/transcripts

### Reports

- POST /reports/daily
- POST /reports/troubleshooting
- POST /reports/portfolio
- GET /reports/today
- GET /reports
- GET /reports/{report_id}
- PATCH /reports/{report_id}
- POST /reports/{report_id}/export

### Settings

- GET /settings
- PATCH /settings
- GET /settings/private-apps
- POST /settings/private-apps
- DELETE /settings/private-apps/{app_name}

## 10. UI Direction

The UI has three areas:

### Floating Widget

States:

- Collapsed
- Stopped
- Active recording
- Paused
- Meeting mode
- Private app detected
- Error
- Quick memo input

Primary actions:

- Start recording
- Pause
- Resume
- Stop
- Add memo
- Start/end meeting mode
- Open dashboard

### Menu Bar App

Primary actions:

- Show current status
- Start/pause/resume recording
- Start/end meeting mode
- Add quick memo
- Open dashboard
- Open settings
- Quit app

### Local Web Dashboard

Main screens:

- Today dashboard
- Timeline
- Report generation
- Report detail/edit
- Troubleshooting
- Portfolio snippets
- Projects
- Settings
- Private apps

## 11. Privacy and Data Policy

The app should be local-first.

Default policy:

- Do not store raw screenshots.
- Do not store screen recording video.
- Do not store raw meeting audio.
- Store extracted text, events, transcripts, memos, and reports only.
- Keep data in local SQLite.
- Send only compressed and filtered summaries to Gemini.

Private apps should be supported.

Examples:

- KakaoTalk
- Discord DM
- 1Password
- Banking apps/sites
- Personal email
- Other user-configured apps

When a private app is active:

- Stop screen capture.
- Stop OCR.
- Avoid storing window title.
- Show private app state in widget.
- Store only minimal state if needed.

## 12. AI Usage Policy

Do not send all raw events directly to Gemini.

Pipeline:

```text
Raw events
→ grouping
→ deduplication
→ privacy filtering
→ timeline blocks
→ prompt building
→ Gemini
→ report
```

Gemini is used for:

- Daily report generation
- Simple summary generation
- Troubleshooting extraction
- Portfolio snippet generation

AI output should be editable by the user.

AI inference should be treated as a draft, not unquestionable truth.

## 13. Development Principles

Follow these principles:

- Use SQLite initially.
- Use SQLAlchemy ORM.
- Use Alembic from the start.
- Avoid raw SQL unless necessary.
- Keep DB access inside repositories.
- Keep business logic inside services.
- Keep routers thin.
- Keep Swift and web dashboard using the same Python backend APIs.
- Host local backend on 127.0.0.1 only.
- Start with backend first.
- Do not implement Swift capture logic before backend core is stable.
- Start with fake events to test reporting quality.

Layering rule:

```text
router
→ service
→ repository
→ model
→ database
```

Avoid:

```text
router directly doing DB queries, AI calls, and report generation
```

## 14. Initial Development Order

Recommended implementation order:

1. Create repository structure.
2. Set up backend with uv.
3. Install FastAPI, Uvicorn, SQLAlchemy, Alembic, Pydantic, pytest, ruff.
4. Implement GET /health.
5. Configure SQLite connection.
6. Configure Alembic.
7. Implement Project, WorkSession, WorkEvent, ManualMemo models first.
8. Implement recording state APIs.
9. Implement events and memos APIs.
10. Implement minimal local dashboard.
11. Implement timeline builder.
12. Implement Gemini report generation.
13. Add meetings/transcripts.
14. Add screen observations.
15. Add settings/private apps.
16. Add export.
17. Package Python backend.
18. Add Swift macOS client.

## 15. First Codex CLI Task

When using Codex CLI, start with this instruction:

```text
Read docs/PROJECT_CONTEXT.md first.
Then inspect the docs folder for planning documents and spreadsheet specs.

Create the initial backend structure under backend/.

Do not implement the entire product yet.
Only do the following:
1. Set up a FastAPI project using uv.
2. Add SQLAlchemy and Alembic.
3. Create the app folder structure described in PROJECT_CONTEXT.md.
4. Implement GET /health.
5. Configure SQLite connection.
6. Prepare base files for models, schemas, repositories, services, and routers.
7. Add a minimal README with local run commands.

Important constraints:
- Use SQLite initially.
- Use SQLAlchemy ORM.
- Use Alembic.
- Host must be 127.0.0.1.
- Port must be 8765.
- Keep router → service → repository structure.
- Do not use Docker.
- Do not implement Swift code yet.
```

## 16. Important Documents

The docs folder may contain:

- Mac Ai Worklog Agent Planning Doc.pdf
- Worklog Agent Backend Architecture Spec.pdf
- Worklog Agent Figma Wireframe Spec.pdf
- worklog_agent_table_spec.xlsx
- worklog_agent_api_spec.xlsx
- worklog_agent_ui_flow_spec.xlsx

Recommended reading order for AI agents:

1. PROJECT_CONTEXT.md
2. Backend Architecture Spec
3. Table Spec
4. API Spec
5. UI Flow Spec
6. Planning Doc
7. Figma Wireframe Spec

## 17. Current Decision Summary

Confirmed decisions:

- Project is macOS-first.
- Initial app is personal/local-first.
- Backend starts first.
- Initial DB is SQLite.
- PostgreSQL is not used initially.
- SQLAlchemy + Alembic should be used to keep PostgreSQL migration possible later.
- Swift is used for macOS-native UI, capture, permissions, and widget.
- Python is used for backend, AI, timeline, reports, and dashboard.
- Docker is not needed for the first implementation.
- Final packaging target is `.app`, later `.dmg`.
- Initial implementation should focus on backend foundations, not full capture/audio features.
