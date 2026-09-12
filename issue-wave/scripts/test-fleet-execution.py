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
           'FLEET_COORDINATOR': 'first'}

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
    change('reserve', request(identity))
    assert records()[identity] == first
    assert len(records()) == 2 and first['state'] == 'reserved'
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
    run('halt', 'regression triage', owner='second')
    change('dispatch', dict(request_id='minix', evidence='ordinary halted'), owner='second', expected=1)
    change('reserve', request('halted', 'other'), owner='second', expected=1)
    triage = {**request('triage', 'other'), 'triage_reason': 'named regression verification'}
    change('reserve', triage, owner='second')
    change('reserve', {**request('second-triage', 'another'), 'triage_reason': 'another'}, owner='second', expected=1)
    change('dispatch', dict(request_id='triage', evidence='triage runner invocation'), owner='second')
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
    assert records()['triage']['state'] == 'launching'
    print('PASS: conflicts, independent boxes, idempotency, adoption, halt, uncertainty and terminal evidence')
