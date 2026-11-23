import os
import sys

os.environ.setdefault(
    "DATABASE_URL", "postgresql+asyncpg://u:p@localhost/db"
)
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest


class FakeState:
    def __init__(self, profile):
        self.auth_user = profile


class FakeRequest:
    def __init__(self, profile):
        self.state = FakeState(profile)


@pytest.fixture
def make_request():
    return FakeRequest
