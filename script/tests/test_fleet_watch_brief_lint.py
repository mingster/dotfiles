"""#1884: undecodable brief-lint output must not kill the issue scan pass."""
import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fleet_watch', Path(__file__).parent.parent / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)


class BriefLintUndecodableOutput(unittest.TestCase):
    def test_decode_error_from_run_reports_brief_lint_failed(self):
        def run(*_args, **_kwargs):
            raise UnicodeDecodeError('utf-8', b"'\xbe", 1, 2, 'invalid start byte')

        self.assertEqual(fw.brief_lint_missing('/tmp/spec.md', run=run), ['brief-lint failed'])

    def test_real_invalid_utf8_stderr_is_replaced_not_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / 'brief-lint.sh'
            script.write_bytes(b"printf \"awk: towc: multibyte conversion failure on: '\\276\\n\" >&2\nexit 1\n")
            script.chmod(script.stat().st_mode | stat.S_IXUSR)
            with patch.object(fw, '_brief_lint_script', return_value=str(script)):
                missing = fw.brief_lint_missing(os.path.join(tmp, 'spec.md'))
        self.assertEqual(len(missing), 1)
        self.assertIn('towc: multibyte conversion failure', missing[0])
        self.assertIn('�', missing[0])


if __name__ == '__main__':
    unittest.main()
