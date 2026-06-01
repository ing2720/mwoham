class SelfObservationFilter:
    markers = (
        "127.0.0.1:8765",
        "localhost:8765",
        "대시보드 - 뭐함",
        "타임라인 - 뭐함",
        "리포트 - 뭐함",
        "설정 - 뭐함",
        "작업 기록 자동화 서비스",
    )

    def is_self_service_text(self, text: str | None) -> bool:
        if not text:
            return False
        lowered = text.lower()
        return any(marker.lower() in lowered for marker in self.markers)

    def is_self_service_values(self, values: list[str | None]) -> bool:
        return self.is_self_service_text("\n".join(value for value in values if value))


def get_self_observation_filter() -> SelfObservationFilter:
    return SelfObservationFilter()
