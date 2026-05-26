class MwohamError(Exception):
    """Base exception for backend domain errors."""


class ResourceNotFoundError(MwohamError):
    """Raised when a requested domain resource does not exist."""


class InvalidStateTransitionError(MwohamError):
    """Raised when a recording state transition is not allowed."""
