import shutil
import subprocess
from collections.abc import Iterator
from pathlib import Path

import pytest
from openhost_test_harness import OpenhostStack

APP_DIR = Path(__file__).resolve().parent.parent


def _app_copy_built_from_source(dest: Path) -> Path:
    """Copies the working tree (minus gitignored files) to ``dest``, with Dockerfile.prebuilt as its Dockerfile.

    The deployed Dockerfile only pulls the image main last published, so testing it would test main, not this
    branch: a change to Dockerfile.prebuilt (eg a JITSI_TAG bump) or to the files it copies would go untested.
    """
    listing = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=APP_DIR,
        capture_output=True,
        check=True,
    )
    for rel in listing.stdout.decode().split("\0"):
        if rel and (APP_DIR / rel).is_file():
            (dest / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(APP_DIR / rel, dest / rel)
    shutil.copy2(APP_DIR / "Dockerfile.prebuilt", dest / "Dockerfile")
    return dest


@pytest.fixture(scope="session")
def stack(tmp_path_factory: pytest.TempPathFactory) -> Iterator[OpenhostStack]:
    """Builds Dockerfile.prebuilt and deploys the app through the real router; returns once the app is running."""
    app_dir = _app_copy_built_from_source(tmp_path_factory.mktemp("app"))
    # The full build pulls five Jitsi images and installs the whole stack, well over the default 5 minutes on CI.
    with OpenhostStack(app_dir=app_dir, deploy_timeout=2400) as s:
        yield s
