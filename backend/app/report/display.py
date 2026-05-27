CREATED_BY_LABELS = {
    "ai": "AI",
    "system": "시스템",
    "user": "사용자",
}

REPORT_MODE_LABELS = {
    "detailed": "상세 리포트",
    "simple": "간단 리포트",
}


def format_created_by(value: str) -> str:
    return CREATED_BY_LABELS.get(value, value)


def format_report_mode(value: str) -> str:
    return REPORT_MODE_LABELS.get(value, value)
