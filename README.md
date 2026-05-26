# mwoham
뭐함은 맥에서 내가 보고, 말하고, 작업한 흐름을 AI가 정리해주는 개인용 작업 기록 에이전트입니다.

## CI/CD

- Backend CI: push/PR에서 `ruff`, `pytest`, `alembic current`를 실행합니다.
- Backend Release: `v*` 태그 또는 수동 실행 시 backend 아카이브를 생성합니다.
