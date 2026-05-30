"""Exception hierarchy for the PAR runtime."""


class PARError(Exception):
    """Base exception for PAR runtime errors."""
    pass


class PARInitError(PARError):
    """Failed to initialize the PAR runtime."""
    pass


class PARInvokeError(PARError):
    """Agent invocation failed."""
    pass


class PARToolError(PARError):
    """Tool registration failed."""
    pass


class PARWorkflowError(PARError):
    """Workflow operation failed."""
    pass
