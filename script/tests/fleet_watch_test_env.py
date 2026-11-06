"""Shared test env for fleet-watch main(); keeps pass logs off the real default path."""
import os
from pathlib import Path
from unittest.mock import patch


def isolated_main_env(tmp_dir):
    """Set HOME and FLEET_WATCH_LOG_PATH under tmp_dir for fleet-watch main() tests."""
    p = Path(tmp_dir)
    log_path = p / 'fleet-watch-test.log'
    return patch.dict(os.environ, {'HOME': str(p), 'FLEET_WATCH_LOG_PATH': str(log_path)}, clear=False)


def env_main_uses_default_log_under_home(home_dir):
    """Full os.environ copy with HOME set and FLEET_WATCH_LOG_PATH unset (default log under HOME)."""
    env = dict(os.environ)
    env.pop('FLEET_WATCH_LOG_PATH', None)
    env['HOME'] = str(home_dir)
    return env


def redirect_main_log_under(dir_path):
    """Only FLEET_WATCH_LOG_PATH under dir_path; leaves HOME unchanged (for tests that depend on it)."""
    log_path = Path(dir_path) / 'fleet-watch-test.log'
    return patch.dict(os.environ, {'FLEET_WATCH_LOG_PATH': str(log_path)}, clear=False)
