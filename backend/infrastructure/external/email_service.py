"""
Compatibility wrapper for the active GRANI email service.

The project now keeps all email templates in services.email_service, so legacy
imports from infrastructure.external.email_service continue to receive the same
layout and delivery behavior.
"""
from services.email_service import *  # noqa: F401,F403
