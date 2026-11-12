import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('trust', Path(__file__).resolve().parents[2] / 'tools/macos-trusted-infobases.py')
trust = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trust)

class TrustSetup(unittest.TestCase):
    def test_preserves_other_settings_and_reverses_only_named_grant(self):
        before = '# Existing settings\nOther=1\nDisableUnsafeActionProtection=existing\n'
        changed = trust.transform(before, ['^File="/test"'])
        self.assertEqual(trust.transform(changed, ['^File="/test"']), changed)
        self.assertEqual(trust.transform(changed, ['^File="/test"'], revoke=True), before)

    def test_spaced_existing_setting_is_updated_without_duplicate(self):
        changed = trust.transform('Other=1\nDisableUnsafeActionProtection = existing\n', ['new'])
        self.assertEqual(changed.count('DisableUnsafeActionProtection'), 1)
        self.assertIn('existing;new', changed)

    def test_revoke_can_address_a_deleted_test_base(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder).resolve() / 'removed'
            pattern = trust.base_pattern(str(base), require_existing=False)
            self.assertEqual(trust.transform(trust.KEY + '=' + pattern + '\n', [pattern], revoke=True), '')

    def test_rejects_ambiguous_configuration(self):
        with self.assertRaises(ValueError):
            trust.transform('DisableUnsafeActionProtection=a\nDisableUnsafeActionProtection=b\n', ['c'])

    def test_posix_pattern_matches_only_exact_base(self):
        with tempfile.TemporaryDirectory(prefix='runner.trust[') as folder:
            base = Path(folder).resolve() / 'test(1)'
            base.mkdir()
            (base / '1Cv8.1CD').touch()
            pattern = trust.base_pattern(str(base))
            self.assertTrue(pattern.startswith('^File="'))
            self.assertTrue(pattern.endswith('".*$'))
            self.assertIn('test(1)', pattern)
            if Path('/usr/bin/grep').is_file():
                for connection, expected in [(f'File="{base}";', 0), (f'File="{base}-other";', 1),
                                             (f'File="{base}/nested";', 1), (f'Srvr="{base}";', 1)]:
                    result = subprocess.run(['/usr/bin/grep', '-qx', pattern], input=connection, text=True)
                    self.assertEqual(result.returncode, expected)

    def test_default_config_path_follows_platform_layout(self):
        win = trust.default_config_path(os_name='nt', env={'LOCALAPPDATA': '/tmp/localappdata'})
        self.assertEqual(win.as_posix().endswith('localappdata/1C/1cv8/conf/conf.cfg'), True)
        mac = trust.default_config_path(os_name='posix', env={})
        self.assertEqual(mac.as_posix().endswith('.1cv8/1C/1cv8/conf/conf.cfg'), True)

    def test_rejects_injection_in_base_name(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder) / 'base;all'
            base.mkdir()
            (base / '1Cv8.1CD').touch()
            with self.assertRaises(ValueError): trust.base_pattern(str(base))

if __name__ == '__main__': unittest.main()
