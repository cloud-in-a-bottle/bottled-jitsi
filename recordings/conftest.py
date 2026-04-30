"""Tests in this directory import ``server`` directly; make that
import work whether pytest is invoked from the repo root or from
this directory.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
