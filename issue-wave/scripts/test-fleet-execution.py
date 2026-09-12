#!/usr/bin/env python3
"""Exercise the actual shell/anchor transitions without SSH or real fleet state."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile

SCRIPT = Path(__file__).with_name('fleet-worker.sh')
with tempfile.TemporaryDirectory(prefix='fleet-execution-') as temporary:
    root = Path(temporary)
    env = {**os.environ, 'FLEET_ANCHOR': 'local', 'FLEET_LOCAL_BOX': 'fixture',
           'ISSUE_WAVE_STATE': str(root), 'FLEET_ANCHOR_STATE': str(root),
           'FLEET_COORDINATOR': 'first', 'FLEET_LOCK_WAIT': '10',
           'FLEET_BOXES': 'rog minix other another case-one case-two'}

    def run(*args, owner='first', expected=0):
        result = subprocess.run(['bash', str(SCRIPT), *args], env={**env, 'FLEET_COORDINATOR': owner},
                                text=True, capture_output=True, timeout=20)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        return result.stdout

    def change(action, data, owner='first', expected=0):
        with tempfile.NamedTemporaryFile(mode='w', dir=root, suffix='.input') as stream:
            json.dump(data, stream)
            stream.flush()
            return run('execution', action, stream.name, owner=owner, expected=expected)

    def request(identity, host='rog'):
        return dict(request_id=identity, wave='wave', worker=identity, transport='subagent',
                    issue='repo#129', purpose='fixture', agent_host='mac', execution_host=host,
                    repository='owner/repo', requested_revision='origin/main', kind='correctness')

    def records():
        return {r['request_id']: r for r in json.loads(run('execution', 'list'))}

    run('claim')
    change('reserve', {**request('bad-triage'), 'triage_reason': True}, expected=1)
    change('reserve', {**request('premarked'), 'triage_reason': 'future triage'}, expected=1)
    assert records() == {}
    mixed_case = request('CaseJob', 'case-one')
    change('reserve', mixed_case)
    case_record = records()['CaseJob']
    case_bytes = (root / 'executions' / 'CaseJob.json').read_bytes()
    change('reserve', request('casejob', 'case-two'), expected=1)
    assert records() == {'CaseJob': case_record}
    for operation in ['dispatch', 'record', 'reconcile', 'conclude']:
        change(operation, dict(request_id='casejob', evidence='must not alias'), expected=1)
        assert (root / 'executions' / 'CaseJob.json').read_bytes() == case_bytes
    change('reserve', mixed_case)
    change('conclude', dict(request_id='CaseJob', verdict='not-launched',
                           log='/logs/case-check', evidence='fixture never dispatched'))
    # Two simultaneous ROG requests cannot both win. Independent Minix can proceed.
    def contend(identity):
        try:
            change('reserve', request(identity))
            return identity
        except AssertionError as exc:
            assert 'box owned by' in str(exc), exc
            return None
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        winners = [name for name in pool.map(contend, ['worker-rog', 'integration-rog']) if name]
    assert len(winners) == 1
    identity = winners[0]
    change('reserve', request('minix', 'minix'))
    first = records()[identity]
    owner_bytes = (root / 'executions' / (identity + '.json')).read_bytes()
    for alias in ['ROG', 'rog-alias']:
        change('reserve', request('wrong-host', alias), expected=1)
        assert (root / 'executions' / (identity + '.json')).read_bytes() == owner_bytes
    sibling_path = root / 'executions' / 'minix.json'
    sibling_bytes = sibling_path.read_bytes()
    # A malformed unrelated owner must block dispatch of an otherwise valid request.
    for missing in ['request', 'lease_token', 'history']:
        broken = json.loads(sibling_bytes)
        del broken[missing]
        sibling_path.write_text(json.dumps(broken))
        change('dispatch', dict(request_id=identity, evidence='must fail closed'), expected=1)
        assert json.loads((root / 'executions' / (identity + '.json')).read_text()) == first
    broken = json.loads(sibling_bytes)
    del broken['request']['execution_host']
    sibling_path.write_text(json.dumps(broken))
    change('dispatch', dict(request_id=identity, evidence='unknown sibling box'), expected=1)
    sibling_path.write_bytes(sibling_bytes)
    legacy = json.loads(sibling_bytes)
    legacy['request']['execution_host'] = 'old-minix-alias'
    sibling_path.write_text(json.dumps(legacy))
    change('dispatch', dict(request_id=identity, evidence='unknown legacy ownership'), expected=1)
    change('reconcile', dict(request_id='minix', state='reserved', evidence='legacy record remains reconcilable'))
    assert records()['minix']['request']['execution_host'] == 'old-minix-alias'
    sibling_path.write_bytes(sibling_bytes)
    change('reserve', request(identity))
    assert records()[identity] == first
    assert len(records()) == 3 and first['state'] == 'reserved'
    change('reserve', {**request(identity), 'purpose': 'different'}, expected=1)
    change('dispatch', dict(request_id=identity, evidence='about to invoke runner'))
    change('dispatch', dict(request_id=identity, evidence='blind retry'), expected=1)
    change('record', dict(request_id=identity, state='uncertain', evidence='SSH disconnected'))
    change('reserve', request('conflict'), expected=1)
    run('claim', '--take', owner='second')
    change('record', dict(request_id=identity, state='running', evidence='stale writer'), expected=1)
    assert records()[identity]['state'] == 'uncertain'
    change('dispatch', dict(request_id='minix', evidence='new coordinator'), owner='second', expected=1)
    change('reconcile', dict(request_id='minix', state='reserved', evidence='runner ledger proves no launch'), owner='second')
    for state in ['running', 'uncertain']:
        change('record', dict(request_id='minix', state=state, evidence='no dispatch'), owner='second', expected=1)
    change('reconcile', dict(request_id='minix', state='uncertain', evidence='prelaunch outcome unclear'), owner='second')
    change('reconcile', dict(request_id='minix', state='reserved', evidence='runner ledger proves no launch'), owner='second')
    run('halt', 'regression triage', owner='second')
    change('dispatch', dict(request_id='minix', evidence='ordinary halted'), owner='second', expected=1)
    change('reserve', request('halted', 'other'), owner='second', expected=1)
    triage = {**request('triage', 'other'), 'triage_reason': 'named regression verification'}
    change('reserve', triage, owner='second')
    change('reserve', {**request('second-triage', 'another'), 'triage_reason': 'another'}, owner='second', expected=1)
    old_halt = records()['triage']['halt_identity']
    run('halt', 'updated regression reason', owner='second')
    assert old_halt in (root / 'HALT').read_text()
    change('reserve', {**request('reason-update-triage', 'another'), 'triage_reason': 'second slot'}, owner='second', expected=1)
    run('claim', '--take', owner='third')
    run('halt', 'adopted regression reason', owner='third')
    assert old_halt in (root / 'HALT').read_text()
    change('reconcile', dict(request_id='triage', state='reserved', evidence='adopter verified no launch'), owner='third')
    change('dispatch', dict(request_id='triage', evidence='same generation after adoption'), owner='third')
    # No runner was invoked by this fixture: reset through explicit evidence reconciliation.
    change('reconcile', dict(request_id='triage', state='reserved', evidence='fixture never invoked runner'), owner='third')
    run('claim', '--take', owner='second')
    change('reconcile', dict(request_id='triage', state='reserved', evidence='ownership returned; no runner'), owner='second')
    run('resume-launches', owner='second')
    change('dispatch', dict(request_id='triage', evidence='ended halt'), owner='second', expected=1)
    # Identical reasons, even within one second, still create distinct halt generations.
    run('halt', 'regression triage', owner='second')
    change('dispatch', dict(request_id='triage', evidence='stale exception'), owner='second', expected=1)
    change('reserve', {**request('occupied-old-box', 'other'), 'triage_reason': 'new halt'}, owner='second', expected=1)
    new_triage = {**request('current-triage', 'another'), 'triage_reason': 'current regression'}
    change('reserve', new_triage, owner='second')
    assert records()['current-triage']['halt_identity'] != old_halt
    change('dispatch', dict(request_id='current-triage', evidence='current triage runner invocation'), owner='second')
    change('conclude', dict(request_id=identity, verdict='pass', evidence='worker handed back', log='worker.log'), owner='second', expected=1)
    for verdict in ['pass', 'fail', 'timeout', 'cancelled']:
        name = identity if verdict == 'pass' else verdict
        if verdict != 'pass':
            run('resume-launches', owner='second')
            change('reserve', request(name), owner='second')
            change('dispatch', dict(request_id=name, evidence='runner starting'), owner='second')
        result = dict(request_id=name, verdict=verdict, evidence='runner terminal record; process stopped',
                      log='/logs/' + name, observed_sha='a'*40, remote_checkout='/work/' + name,
                      handle='runner-' + name)
        change('conclude', result, owner='second')
        change('conclude', result, owner='second')
        assert records()[name]['verdict'] == verdict
        assert records()[name]['log'] == '/logs/' + name
    change('conclude', dict(request_id='minix', verdict='not-launched', log='/logs/reconciliation',
                            evidence='verified invocation never began'), owner='second')
    change('record', dict(request_id='triage', state='uncertain', observed_sha='main', evidence='bad SHA'), owner='second', expected=1)
    # Real durable records survive ownership change; no timeout or worker status frees them.
    assert records()['triage']['state'] == 'reserved'
    assert records()['current-triage']['state'] == 'launching'
    print('PASS: conflicts, independent boxes, idempotency, adoption, halt, uncertainty and terminal evidence')

# Exercise real fsync calls and their publication order, including first directory creation.
import runpy
import stat
import io
from contextlib import redirect_stdout
from unittest.mock import patch

with tempfile.TemporaryDirectory(prefix='fleet-durable-') as temporary:
    events = []
    real_sync, real_replace = os.fsync, os.replace

    def sync(descriptor):
        events.append('directory' if stat.S_ISDIR(os.fstat(descriptor).st_mode) else 'file')
        return real_sync(descriptor)

    def replace(source, target):
        events.append('replace')
        return real_replace(source, target)

    payload = request('durable')
    with patch('sys.argv', ['helper', temporary, 'reserve', 'owner', 'token', json.dumps(payload), env['FLEET_BOXES']]), \
            patch('os.fsync', side_effect=sync), patch('os.replace', side_effect=replace):
        with redirect_stdout(io.StringIO()):
            runpy.run_path(str(SCRIPT.with_name('fleet-execution.py')))
    assert events == ['directory', 'file', 'replace', 'directory'], events
    events.clear()
    with patch('sys.argv', ['helper', temporary, 'reserve', 'owner', 'token', json.dumps(payload), env['FLEET_BOXES']]), \
            patch('os.fsync', side_effect=sync), redirect_stdout(io.StringIO()):
        runpy.run_path(str(SCRIPT.with_name('fleet-execution.py')))
    assert events == ['directory', 'directory'], events
    print('PASS: parent and record directory synced around atomic publication')
