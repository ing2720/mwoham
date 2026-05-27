from secrets import compare_digest

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.core.config import settings

bearer_scheme = HTTPBearer(auto_error=False)


def require_local_api_token(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
) -> None:
    expected_token = settings.local_api_token
    if not expected_token:
        return

    if credentials is None or not compare_digest(credentials.credentials, expected_token):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing local API token.",
            headers={"WWW-Authenticate": "Bearer"},
        )
