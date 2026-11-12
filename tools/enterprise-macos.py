#!/usr/bin/env python3
"""Detached macOS run observer. Never adopts arbitrary processes or infobases."""
import argparse
import json
import re
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(os.environ.get('VANESSA_RUNNER_STATE_DIR', str(Path.home() / 'Library/Application Support/VanessaRunner/runs')))

def write(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False))
    os.replace(tmp, path)

def native_command(command_line):
    argv = shlex.split(command_line)
    executable = Path(argv[0])
    if sys.platform == 'darwin' and executable.name in ('1cv8', '1cv8c'):
        bundled = executable.parent / (executable.name + '.app') / 'Contents/MacOS' / executable.name
        if bundled.is_file():
            argv[0] = str(bundled)
    return argv

def validate_infobase(argv):
    # A typo must fail before 1C opens an interactive infobase-selection dialog.
    for index, argument in enumerate(argv[1:], 1):
        if not argument.lower().startswith('/f'):
            continue
        path = argument[2:] if len(argument) > 2 else (argv[index + 1] if index + 1 < len(argv) else '')
        if not path or not (Path(path) / '1Cv8.1CD').is_file():
            raise ValueError('Файловая база не найдена: ' + path + '. Проверьте ibconnection; база не создавалась.')
        return

class RuntimeErrorTail:
    """Read only appended text event records; base evidence is not session proof."""
    def __init__(self, argv):
        self.directory = None
        for index, arg in enumerate(argv[1:], 1):
            if arg.lower().startswith('/f'):
                path = arg[2:] or (argv[index + 1] if index + 1 < len(argv) else '')
                self.directory = Path(path) / '1Cv8Log'
                break
        self.offsets = {p: p.stat().st_size for p in self.files()}
        self.pending = {}

    def files(self):
        return list(self.directory.glob('*.lgp')) if self.directory else []

    def poll(self):
        errors = []
        for path in self.files():
            size = path.stat().st_size
            offset = self.offsets.get(path, 0)
            if size < offset:
                offset = 0
                self.pending.pop(path, None)
            with path.open('rb') as stream:
                stream.seek(offset)
                data = stream.read(262144)
                self.offsets[path] = stream.tell()
            data = self.pending.get(path, b'') + data
            # Complete records end with a standalone closing brace, not a field.
            records = re.split(rb'\r?\n},?\r?\n', data)
            self.pending[path] = records.pop()[-262144:]
            for record in records:
                text = record.decode('utf-8-sig', errors='replace')
                match = re.search(r',E,"((?:""|[^"])*)"', text)
                if match:
                    errors.append(dict(source=str(path), scope='infobase',
                        sessionConfirmed=False, message=match.group(1).replace('""', '"')[-8192:]))
        return errors

def identity(pid):
    out = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart='], capture_output=True, text=True)
    return out.stdout.strip() or None

def members(pgid):
    out = subprocess.check_output(['/bin/ps', '-axo', 'pid=,pgid=,stat='], text=True)
    return [int(row[0]) for line in out.splitlines() if len(row := line.split()) == 3 and int(row[1]) == pgid and not row[2].startswith('Z')]

def report_evidence(status_path):
    settings = Path(status_path).parent / 'vanessa-effective.json'
    if not settings.is_file():
        return dict(status='missing', message='No effective Vanessa settings; report not verified')
    try:
        config = json.loads(settings.read_text(encoding='utf-8-sig'))
        directory = config.get('КаталогOutputjUnit')
        files = sorted(Path(directory).glob('*.xml')) if directory else []
        if not files:
            return dict(status='missing', message='No JUnit report. Scenario status alone does not prove the reported defect.')
        cases = []
        for file in files:
            for case in ET.parse(file).iter('testcase'):
                outcome = next((node for node in case if node.tag in ('error', 'failure', 'skipped')), None)
                cases.append(dict(name=case.get('name', ''), status=outcome.tag if outcome is not None else 'passed',
                                  message=(''.join(outcome.itertext()) or outcome.get('message', ''))[:4096] if outcome is not None else ''))
        return dict(status='available' if cases else 'empty', files=list(map(str, files)), cases=cases[:50],
                    message='Inspect the actual failed step: a syntax, missing-step or preparation error is not proof of a business defect.')
    except (OSError, ValueError, ET.ParseError) as error:
        return dict(status='unreadable', message=str(error))

def status(folder, run_id):
    try:
        state = json.loads((folder / 'state.json').read_text())
    except FileNotFoundError:
        return dict(runId=run_id, state='supervision_lost', result='failed', observationError='Run is not recorded', activeProcessCount=None)
    if state['state'] != 'exited' and identity(state['observerPid']) != state['observerIdentity']:
        state.update(state='supervision_lost', result='failed', activeProcessCount=None, observationError='Observer identity is no longer present')
    if state['state'] == 'exited':
        spec = json.loads((folder / 'spec.json').read_text())
        if spec.get('kind') == 'vanessa' and spec.get('statusPath'):
            state['reportEvidence'] = report_evidence(spec['statusPath'])
    return state

def observe(folder, run_id):
    spec = json.loads((folder / 'spec.json').read_text())
    state = dict(runId=run_id, driverVersion='macos-0.1.0', processTracking='posix_process_group', state='starting', result='pending', scenarioStatus='unknown', cleanupStatus='pending', activeProcessCount=0, processes=[], exitCode=None, observerPid=os.getpid(), observerIdentity=identity(os.getpid()))
    runtime_errors = RuntimeErrorTail(shlex.split(spec['commandLine']))
    state['applicationReadiness'] = 'unverified'
    previous = None
    def save():
        nonlocal previous
        value = json.dumps(state, sort_keys=True)
        if value != previous:
            state['observationId'] = str(uuid.uuid4())
            write(folder / 'state.json', state)
            previous = json.dumps(state, sort_keys=True)
    try:
        with (folder / 'output.log').open('ab') as log:
            child = subprocess.Popen(native_command(spec['commandLine']), stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        pid = child.pid
        state.update(state='running', activeProcessCount=1, processes=[dict(pid=pid, role='manager', identity=identity(pid), exitCode=None)])
        save()
        cancelled = False
        close_requested = False
        manager_exited_at = None
        cleanup_sent = False
        while True:
            try:
                errors = runtime_errors.poll()
                if errors:
                    state['runtimeErrors'] = (state.get('runtimeErrors', []) + errors)[-10:]
                    state['applicationReadiness'] = 'needs_attention'
                    state['lastPlatformError'] = errors[-1]['message']
            except OSError as error:
                state['runtimeLogObservationError'] = str(error)
            code = child.poll()
            live = members(pid)
            state['activeProcessCount'] = len(live)
            state['processes'][0]['exitCode'] = code
            state['exitCode'] = code
            marker = Path(spec['statusPath']) if spec.get('statusPath') else None
            if marker and marker.exists():
                text = marker.read_text(encoding='utf-8-sig').strip()
                state['scenarioStatus'] = 'passed' if text == '0' else 'failed'
            if (folder / 'stop').exists() and not close_requested:
                close_requested = True
                state['cleanupStatus'] = 'close_pending'
                if live:
                    with (folder / 'output.log').open('ab') as log:
                        subprocess.run(['/usr/bin/swift', str(Path(__file__).with_name('enterprise-macos-close.swift')), *map(str, live)], stdout=log, stderr=log, timeout=30)
            if (folder / 'cancel').exists() and not cancelled:
                # Group belongs to this child and is still observed continuously.
                for owned in live:
                    try: os.kill(owned, signal.SIGTERM)
                    except ProcessLookupError: pass
                cancelled = True
            # A finished test manager cannot close a TestClient which missed its
            # connection timeout. Reap only this continuously observed run group.
            if code is not None and live and spec.get('kind') == 'vanessa':
                if manager_exited_at is None:
                    manager_exited_at = time.monotonic()
                if not cleanup_sent and time.monotonic() - manager_exited_at >= 3:
                    for owned in live:
                        try: os.kill(owned, signal.SIGTERM)
                        except ProcessLookupError: pass
                    cleanup_sent = True
                    state['terminatedRemainingChildren'] = True
                    state['cleanupStatus'] = 'close_pending'
            if code is not None and not live:
                passed = code == 0 and state['scenarioStatus'] == 'passed' and not cancelled and not cleanup_sent
                state.update(state='exited', cleanupStatus='exited', result='passed' if passed else 'failed')
                if not passed: state['failureReason'] = 'cancelled' if cancelled else ('bad_exit' if code else ('remaining_children' if cleanup_sent and state['scenarioStatus'] == 'passed' else 'scenario_' + state['scenarioStatus']))
                if not passed:
                    argv = shlex.split(spec['commandLine'])
                    for index, argument in enumerate(argv[:-1]):
                        if argument.lower() == '/out':
                            platform_log = Path(argv[index + 1])
                            if platform_log.is_file():
                                state['lastPlatformError'] = platform_log.read_text(encoding='utf-8-sig', errors='replace')[-4096:]
                save()
                return
            save()
            time.sleep(.2)
    except Exception as error:
        state.update(state='supervision_error', result='failed', observationError=str(error), activeProcessCount=None)
        save()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('-Action', required=True)
    parser.add_argument('-RunId', required=True)
    parser.add_argument('-SpecPath', default='')
    parser.add_argument('-TimeoutSeconds', type=float, default=5)
    args = parser.parse_args()
    run_id = str(uuid.UUID(args.RunId))
    folder = ROOT / run_id
    if args.Action == 'observe':
        observe(folder, run_id)
        return
    if args.Action == 'launch':
        spec = json.loads(Path(args.SpecPath).read_text(encoding='utf-8-sig'))
        if spec.get('preparationCommandLine') or spec.get('acknowledgeDeveloperLicense'):
            raise ValueError('Prepared launches and automatic license dialog handling are not supported on macOS')
        argv = shlex.split(spec['commandLine'])
        if not argv or not Path(argv[0]).is_absolute():
            raise ValueError('An absolute executable path is required')
        validate_infobase(argv)
        if spec.get('statusPath') and Path(spec['statusPath']).exists():
            raise ValueError('Scenario status already exists; use a fresh run')
        ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
        folder.mkdir(mode=0o700)
        write(folder / 'spec.json', spec)
        with (folder / 'observer.log').open('ab') as log:
            subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '-Action', 'observe', '-RunId', run_id], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        deadline = time.monotonic() + 10
        while not (folder / 'state.json').exists() and time.monotonic() < deadline:
            time.sleep(.05)
    elif args.Action == 'await':
        while True:
            state = status(folder, run_id)
            if state.get('observationId') != args.SpecPath or state['state'] in ('exited','supervision_lost','supervision_error'): break
            time.sleep(.2)
    elif args.Action in ('cancel', 'stop'):
        state = status(folder, run_id)
        if state['state'] not in ('exited','supervision_lost','supervision_error'):
            (folder / args.Action).touch()
            deadline = time.monotonic() + min(max(args.TimeoutSeconds, 0), 30)
            while args.Action == 'stop' and time.monotonic() < deadline:
                if status(folder, run_id)['state'] in ('exited','supervision_error','supervision_lost'): break
                time.sleep(.1)
    elif args.Action not in ('status', 'recover'):
        raise ValueError('Action not supported on macOS: ' + args.Action)
    print(json.dumps(status(folder, run_id), ensure_ascii=False))

if __name__ == '__main__':
    main()
