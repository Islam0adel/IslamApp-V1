"""Explicit pre-activation fixtures for isolated legacy payload/masking tests."""
async def legacy_delivery_policy(company_code, hr_target=None):
    return None, None


def payload_only_manager():
    """Masking-only fixture. Source freshness is tested with real identity fixtures.

    Old masking tests deliberately omit UID/email/company and cannot authenticate.
    Never use this fixture to assert account revocation or socket authentication.
    """
    from app.core.sync import ConnectionManager
    class PayloadManager(ConnectionManager):
        async def _fresh_delivery_profiles(self, *args, **kwargs):
            return True
    return PayloadManager(policy_loader=legacy_delivery_policy)
