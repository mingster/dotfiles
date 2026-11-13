"""Shared test env for fleet-watch main(); keeps pass logs off the real default path."""
import os
from pathlib import Path
from unittest.mock import patch


def isolated_main_env(tmp_dir):
    """Set HOME and FLEET_WATCH_LOG_PATH under tmp_dir for fleet-watch main() tests."""
    p = Path(tmp_dir)
    log_path = p / 'fleet-watch-test.log'
    return patch.dict(os.environ, {'HOME': str(p), 'FLEET_WATCH_LOG_PATH': str(log_path)}, clear=False)


def redirect_main_log_under(dir_path):
    """Only FLEET_WATCH_LOG_PATH under dir_path; leaves HOME unchanged (for tests that depend on it)."""
    log_path = Path(dir_path) / 'fleet-watch-test.log'
    return patch.dict(os.environ, {'FLEET_WATCH_LOG_PATH': str(log_path)}, clear=False)



def quiet_host(test, fw):
    """For one test: stub the coordinator load and free memory reads, so admit() never sees the real host."""
    for name, value in (('coordinator_load_per_core', 0.1), ('coordinator_free_gb', 64.0)):
        patcher = patch.object(fw, name, return_value=value)
        patcher.start()
        test.addCleanup(patcher.stop)
