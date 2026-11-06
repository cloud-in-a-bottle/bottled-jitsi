from collections.abc import Iterator

import pytest
from openhost_test_harness import OpenhostStack


@pytest.fixture(scope="session")
def stack() -> Iterator[OpenhostStack]:
    """Builds the Dockerfile and deploys the app through the real router; returns once the app is running."""
    # The full build pulls five Jitsi images and installs the whole stack, well over the default 5 minutes on CI.
    with OpenhostStack(deploy_timeout=2400) as s:
        yield s
