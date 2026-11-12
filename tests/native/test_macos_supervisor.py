import json
import importlib.util
from unittest.mock import patch
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

HELPER = Path(__file__).resolve().parents[2] / 'tools/enterprise-macos.py'

class NativeExecutable(unittest.TestCase):
    def test_macos_uses_vendor_bundle_without_changing_arguments(self):
        spec = importlib.util.spec_from_file_location('observer', HELPER)
        observer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(observer)
        with tempfile.TemporaryDirectory(prefix='runner native ') as folder:
            executable = Path(folder) / '1cv8c'
            executable.touch()
            bundled = Path(folder) / '1cv8c.app/Contents/MacOS/1cv8c'
            bundled.parent.mkdir(parents=True)
            bundled.touch()
            args = [str(executable), 'ENTERPRISE', '/F/test base', '/CStartFeaturePlayer;VAParams=/test file']
            with patch.object(observer.sys, 'platform', 'darwin'):
                self.assertEqual(observer.native_command(shlex.join(args)), [str(bundled), *args[1:]])
            bundled.unlink()
            self.assertEqual(observer.native_command(shlex.join(args)), args)

class InfobasePreflight(unittest.TestCase):
    def test_file_connection_must_exist_before_launch(self):
        spec = importlib.util.spec_from_file_location('observer', HELPER)
        observer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(observer)
        with tempfile.TemporaryDirectory(prefix='runner base ') as folder:
            base = Path(folder) / 'TestInfobase'
            for connection in ([f'/F{base}'], ['/F', str(base)]):
                with self.assertRaisesRegex(ValueError, 'Файловая база не найдена'):
                    observer.validate_infobase(['/opt/1cv8/1cv8c', 'ENTERPRISE', *connection])
            base.mkdir()
            (base / '1Cv8.1CD').touch()
            observer.validate_infobase(['/opt/1cv8/1cv8c', 'ENTERPRISE', f'/F{base}'])
            observer.validate_infobase(['/opt/1cv8/1cv8c', 'ENTERPRISE', '/Sserver/base'])

class ReportEvidence(unittest.TestCase):
    def test_missing_report_is_explicit_and_error_is_not_a_business_proof(self):
        spec = importlib.util.spec_from_file_location('observer', HELPER)
        observer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(observer)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            settings = root / 'vanessa-effective.json'
            settings.write_text(json.dumps({'КаталогOutputjUnit': str(root / 'junit')}))
            self.assertEqual(observer.report_evidence(root / 'scenario.status')['status'], 'missing')
            (root / 'junit').mkdir()
            (root / 'junit/junit.xml').write_text('<testsuites><testsuite><testcase name="Case"><error>Unknown step</error></testcase></testsuite></testsuites>')
            evidence = observer.report_evidence(root / 'scenario.status')
            self.assertEqual(evidence['status'], 'available')
            self.assertEqual(evidence['cases'], [{'name': 'Case', 'status': 'error', 'message': 'Unknown step'}])

class RuntimeErrors(unittest.TestCase):
    def test_only_new_complete_errors_are_reported_without_claiming_session(self):
        spec = importlib.util.spec_from_file_location('observer', HELPER)
        observer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(observer)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            logdir = root / '1Cv8Log'
            logdir.mkdir()
            log = logdir / '20261110.lgp'
            record = '{20261110144354,N,\n{0,0},2,1,2,1,14,E,"{Форма(77,11)}: уже определена (Открыть)",0,\n{"U"},"",0,0,0,1,0,\n{2,1,1,2,1}\n},\n'
            log.write_text(record)
            watcher = observer.RuntimeErrorTail(['/opt/1cv8/1cv8c', 'ENTERPRISE', '/F' + str(root)])
            self.assertEqual(watcher.poll(), [])
            with log.open('a') as stream: stream.write(record[:40])
            self.assertEqual(watcher.poll(), [])
            with log.open('a') as stream: stream.write(record[40:])
            errors = watcher.poll()
            self.assertEqual(len(errors), 1)
            self.assertIn('Форма(77,11)', errors[0]['message'])
            self.assertEqual(errors[0]['scope'], 'infobase')
            self.assertFalse(errors[0]['sessionConfirmed'])
            self.assertEqual(watcher.poll(), [])

class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, VANESSA_RUNNER_STATE_DIR=str(self.root / 'runs'))
        self.run_id = str(uuid.uuid4())

    def tearDown(self):
        self.tmp.cleanup()

    def call(self, action, extra=''):
        args = [sys.executable, str(HELPER), '-Action', action, '-RunId', self.run_id]
        if extra: args += ['-SpecPath', str(extra)]
        return json.loads(subprocess.check_output(args, env=self.env, text=True))

    def run_scenario(self, body):
        status = self.root / 'status.txt'
        script = self.root / 'fixture.py'
        script.write_text(body.replace('STATUS', repr(str(status))))
        spec = self.root / 'spec.json'
        spec.write_text(json.dumps({'kind':'vanessa', 'statusPath':str(status), 'commandLine':shlex.join([sys.executable, str(script)])}))
        self.call('launch', spec)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = self.call('status')
            if state['state'] == 'exited': return state
            time.sleep(.1)
        self.fail('watcher did not settle')

    def test_pass_requires_marker_and_exit(self):
        state = self.run_scenario('from pathlib import Path\nPath(STATUS).write_text("0")')
        self.assertEqual(state['result'], 'passed')
        self.assertEqual(state['activeProcessCount'], 0)

    def test_zero_exit_without_marker_is_not_pass(self):
        state = self.run_scenario('pass')
        self.assertEqual(state['result'], 'failed')
        self.assertEqual(state['scenarioStatus'], 'unknown')

    def test_bad_exit_overrides_pass_marker(self):
        state = self.run_scenario('from pathlib import Path\nPath(STATUS).write_text("0")\nraise SystemExit(7)')
        self.assertEqual(state['result'], 'failed')
        self.assertEqual(state['exitCode'], 7)

    def test_children_must_exit_before_cleanup_passes(self):
        state = self.run_scenario('import subprocess, sys\nfrom pathlib import Path\nPath(STATUS).write_text("0")\nsubprocess.Popen([sys.executable, "-c", "import time; time.sleep(.5)"])')
        self.assertEqual(state['result'], 'passed')
        self.assertEqual(state['activeProcessCount'], 0)

    def test_finished_manager_does_not_leave_test_client_running(self):
        try:
            state = self.run_scenario('import subprocess, sys\nfrom pathlib import Path\nsubprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])\nPath(STATUS).write_text("1")')
            self.assertEqual(state['scenarioStatus'], 'failed')
            self.assertEqual(state['result'], 'failed')
            self.assertEqual(state['activeProcessCount'], 0)
            self.assertEqual(state['cleanupStatus'], 'exited')
            self.assertTrue(state['terminatedRemainingChildren'])
        finally:
            self.call('cancel')

    def test_failed_scenario_with_clean_exit_is_not_pass(self):
        state = self.run_scenario('from pathlib import Path\nPath(STATUS).write_text("1")')
        self.assertEqual(state['scenarioStatus'], 'failed')
        self.assertEqual(state['result'], 'failed')
        self.assertEqual(state['cleanupStatus'], 'exited')

    def test_cancel_does_not_touch_an_unrelated_process(self):
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        try:
            script = self.root / 'waiting.py'
            script.write_text('import time; time.sleep(30)')
            spec = self.root / 'spec.json'
            spec.write_text(json.dumps({'kind': 'vanessa', 'statusPath': str(self.root / 'status.txt'),
                                        'commandLine': shlex.join([sys.executable, str(script)])}))
            self.call('launch', spec)
            self.call('cancel')
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                state = self.call('status')
                if state['state'] == 'exited': break
                time.sleep(.1)
            self.assertEqual(state['result'], 'failed')
            self.assertEqual(state['failureReason'], 'cancelled')
            self.assertEqual(state['activeProcessCount'], 0)
            self.assertIsNone(unrelated.poll())
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)

    def test_existing_status_cannot_be_reused(self):
        marker = self.root / 'status.txt'
        marker.write_text('0')
        spec = self.root / 'spec.json'
        spec.write_text(json.dumps({'kind':'vanessa', 'statusPath':str(marker), 'commandLine':'/usr/bin/true'}))
        with self.assertRaises(subprocess.CalledProcessError): self.call('launch', spec)

    def test_unknown_run_is_never_relaunched(self):
        self.assertEqual(self.call('status')['state'], 'supervision_lost')

if __name__ == '__main__': unittest.main()
