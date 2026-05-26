from app.schemas.common import ApiSchema


class HealthResponse(ApiSchema):
    status: str
    version: str
    database: str
