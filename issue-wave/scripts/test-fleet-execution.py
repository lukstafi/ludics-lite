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
    assert json.loads(run('execution', 'list', '--active', '--compact')) == []
    # Host-local CLI and remote native requests contend for the same box, regardless of
    # transport/residence. The same issue can independently reserve another box.
    competitors = {
        "worker-rog": {**request("worker-rog"), "transport": "cli", "agent_host": "rog"},
        "integration-rog": request("integration-rog"),
    }
    def contend(identity):
        try:
            change('reserve', competitors[identity])
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
    assert first['request'] == competitors[identity]
    assert records()['minix']['request']['issue'] == first['request']['issue']
    loser = next(name for name in competitors if name != identity)
    change('reserve', competitors[loser], expected=1)
    assert loser not in records()
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
    change('reserve', competitors[identity])
    assert records()[identity] == first
    assert len(records()) == 3 and first['state'] == 'reserved'
    # Routine supervision needs outstanding ownership, not an ever-growing history dump.
    # Exercise the public shell path and retain default list's full audit records.
    ledger_before = {p.name: p.read_bytes() for p in (root / 'executions').glob('*.json')}
    full = json.loads(run('execution', 'list', owner='reader'))
    active = json.loads(run('execution', 'list', '--active', owner='reader'))
    assert {r['request_id'] for r in active} == {identity, 'minix'}
    compact = json.loads(run('execution', 'list', '--compact', owner='reader'))
    assert compact == [{k: v for k, v in r.items() if k not in {'history', 'lease_token'}}
                       for r in full]
    active_compact = json.loads(run('execution', 'list', '--active', '--compact'))
    assert active_compact == [r for r in compact if r['state'] != 'concluded']
    assert json.loads(run('execution', 'list', '--compact', '--active')) == active_compact
    assert all('history' in r and 'lease_token' in r for r in full)
    run('execution', 'list', '--actve', expected=2)
    assert ledger_before == {p.name: p.read_bytes() for p in (root / 'executions').glob('*.json')}
    # Filtering a terminal record must not hide corruption from the reader.
    terminal_path = root / 'executions' / 'CaseJob.json'
    broken = json.loads(terminal_path.read_bytes())
    del broken['history']
    terminal_path.write_text(json.dumps(broken))
    run('execution', 'list', '--active', '--compact', expected=1)
    terminal_path.write_bytes(ledger_before['CaseJob.json'])
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

# `execution run` (reserve + dispatch under one lock) and per-box correctness slots
# (ludics-lite#157): measurement stays exclusive, correctness shares up to the box's slots.
with tempfile.TemporaryDirectory(prefix='fleet-slots-') as temporary:
    root = Path(temporary)
    env = {**os.environ, 'FLEET_ANCHOR': 'local', 'FLEET_LOCAL_BOX': 'fixture',
           'ISSUE_WAVE_STATE': str(root), 'FLEET_ANCHOR_STATE': str(root),
           'FLEET_COORDINATOR': 'first', 'FLEET_LOCK_WAIT': '10',
           'FLEET_BOXES': 'mac rog minix', 'FLEET_BOX_CORRECTNESS_SLOTS': 'mac=3 rog=1'}

    def run(*args, expected=0, **extra):
        result = subprocess.run(['bash', str(SCRIPT), *args], env={**env, **extra},
                                text=True, capture_output=True, timeout=20)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        return result.stdout + result.stderr

    def change(action, data, expected=0, **extra):
        with tempfile.NamedTemporaryFile(mode='w', dir=root, suffix='.input') as stream:
            json.dump(data, stream)
            stream.flush()
            return run('execution', action, stream.name, expected=expected, **extra)

    def request(identity, host='mac', kind='correctness'):
        return dict(request_id=identity, wave='wave', worker=identity, transport='subagent',
                    issue='repo#157', purpose='fixture', agent_host='mac', execution_host=host,
                    repository='owner/repo', requested_revision='origin/main', kind=kind)

    def records():
        return {r['request_id']: r for r in json.loads(run('execution', 'list'))}

    run('claim')
    # run: one call leaves the record dispatched, with both steps in its history.
    change('run', {**request('run-1'), 'evidence': 'invoking the runner now'})
    first = records()['run-1']
    assert first['state'] == 'launching', first
    assert [e['action'] for e in first['history']] == ['reserve', 'dispatch'], first['history']
    assert first['history'][1]['data'] == {'request_id': 'run-1', 'evidence': 'invoking the runner now'}
    assert first['request'] == request('run-1'), first['request']
    # A repeated run never repeats a launch, and a changed request is a different assignment.
    out = change('run', request('run-1'), expected=1)
    assert 'already dispatched' in out, out
    out = change('run', {**request('run-1'), 'purpose': 'other'}, expected=1)
    assert 'different assignment' in out, out
    assert records()['run-1'] == first
    out = change('run', {**request('run-bad'), 'evidence': ''}, expected=1)
    assert 'evidence' in out and 'run-bad' not in records(), out
    # run on a plain reservation dispatches it; the default dispatch evidence names the step.
    change('reserve', request('run-2'))
    change('run', request('run-2'))
    second = records()['run-2']
    assert second['state'] == 'launching' and [e['action'] for e in second['history']] == ['reserve', 'dispatch']
    assert 'execution run' in second['history'][1]['data']['evidence']
    # Three correctness slots on mac: the third fits, the fourth is refused naming the owners.
    change('run', request('run-3'))
    out = change('run', request('run-4'), expected=1)
    assert 'box owned by' in out and 'correctness slots 3/3 on mac' in out, out
    assert 'run-4' not in records()
    # A standing iteration record (ludics-lite#160) is ownership and evidence, not a running
    # batch: it is admitted past a full box and never fills a slot itself. The slots are taken
    # at run time instead, by `fleet-worker.sh execution slot` around each batch.
    change('run', {**request('iterate-4'), 'standing': True})
    assert records()['iterate-4']['request']['standing'] is True
    out = change('run', request('run-4b'), expected=1)
    assert 'correctness slots 3/3 on mac' in out, out
    assert 'run-4b' not in records()
    change('run', {**request('iterate-5'), 'standing': True})
    # It is loud, not read off the `-iterate` id convention: only `true`, only on correctness.
    out = change('run', {**request('standing-bad'), 'standing': 'yes'}, expected=1)
    assert 'standing must be true when present' in out and 'standing-bad' not in records(), out
    out = change('run', {**request('standing-measure', 'minix', kind='measurement'), 'standing': True}, expected=1)
    assert 'only a correctness reservation can be standing' in out, out
    # An integration run (ludics-lite#401) is a claim the base gate acts on: only `true`, and only
    # on a coordinator's non-standing correctness request. (Its admission and the gate reading it
    # are exercised end to end in test-fleet-worker.sh.)
    coordinator = {**request('integ-bad'), 'transport': 'coordinator'}
    out = change('run', {**coordinator, 'integration': 'yes'}, expected=1)
    assert 'integration must be true when present' in out and 'integ-bad' not in records(), out
    for bad in ({**request('integ-bad'), 'integration': True},
                {**coordinator, 'kind': 'measurement', 'execution_host': 'minix', 'integration': True},
                {**coordinator, 'standing': True, 'integration': True}):
        out = change('run', bad, expected=1)
        assert "only a coordinator's non-standing correctness reservation can be an integration run" in out, out
        assert 'integ-bad' not in records(), out
    change('conclude', dict(request_id='iterate-4', verdict='not-launched', log='/logs/iterate-4',
                            evidence='fixture concluded the standing record at hand-back'))
    change('conclude', dict(request_id='iterate-5', verdict='not-launched', log='/logs/iterate-5',
                            evidence='fixture concluded the standing record at hand-back'))
    # Measurement needs the box to itself, and holds it exclusively once it has it.
    out = change('reserve', request('measure-mac', kind='measurement'), expected=1)
    assert 'measurement needs mac to itself' in out, out
    change('reserve', request('measure-minix', 'minix', kind='measurement'))
    out = change('reserve', request('check-minix', 'minix'), expected=1)
    assert 'a measurement holds minix exclusively' in out, out
    out = change('reserve', request('measure-minix-2', 'minix', kind='measurement'), expected=1)
    assert 'measurement needs minix to itself' in out, out
    # rog has one slot: the second correctness request is refused as before.
    change('reserve', request('check-rog', 'rog'))
    out = change('reserve', request('check-rog-2', 'rog'), expected=1)
    assert 'box owned by' in out and 'correctness slots 1/1 on rog' in out, out
    # An unnamed box has one slot; a malformed spec or one naming a box outside the roster is refused.
    change('reserve', request('lone-rog', 'rog'), expected=1)
    out = change('reserve', request('spec-bad', 'minix'), expected=1, FLEET_BOX_CORRECTNESS_SLOTS='mac=x')
    assert '<box>=<positive n>' in out, out
    out = change('reserve', request('spec-bad', 'minix'), expected=1, FLEET_BOX_CORRECTNESS_SLOTS='other=2')
    assert 'not in FLEET_BOXES' in out, out
    # Evidence naming a box binds to the reserved one, and the binding leaves no field in the record.
    terminal = dict(request_id='run-1', verdict='pass', evidence='runner terminal record; process stopped',
                    log='/logs/run-1', observed_sha='b' * 40, remote_checkout='/work/run-1', handle='runner-run-1')
    out = change('conclude', {**terminal, 'execution_host': 'rog'}, expected=1)
    assert 'evidence from rog cannot conclude an assignment reserved on mac' in out, out
    out = change('conclude', {**terminal, 'execution_host': ''}, expected=1)
    assert records()['run-1']['state'] == 'launching'
    # A concluded correctness run frees its slot.
    change('conclude', {**terminal, 'execution_host': 'mac'})
    assert 'execution_host' not in records()['run-1']['history'][-1]['data']
    change('conclude', terminal)   # the identical retry, without the binding, is still harmless
    change('run', request('run-4'))
    assert records()['run-4']['state'] == 'launching'
    # Under a halt an ordinary run is refused whole (nothing reserved), the named triage run dispatches.
    change('conclude', dict(request_id='measure-minix', verdict='not-launched', log='/logs/measure',
                            evidence='fixture never dispatched'))
    run('halt', 'regression triage')
    out = change('run', request('halted-run', 'minix'), expected=1)
    assert 'fleet halted' in out and 'halted-run' not in records(), out
    change('run', {**request('triage-run', 'minix'), 'triage_reason': 'named regression verification'})
    triage = records()['triage-run']
    assert triage['state'] == 'launching' and triage['halt_identity'], triage
    run('resume-launches')
    print('PASS: execution run, correctness slots, standing records, exclusive measurement, halt')

# One roster entry per physical box (ludics-lite#395): wake-lab.sh's endpoint map says which ssh
# aliases are one box, and a roster naming two of them is refused before it can split a
# measurement's exclusivity. Reads and conclusions stay available under such a roster.
import shutil


def one_entry_per_box():
    # A function, so its env and request helpers do not replace the module-level ones below.
    with tempfile.TemporaryDirectory(prefix='fleet-one-box-') as temporary:
        root = Path(temporary)
        env = {**os.environ, 'FLEET_ANCHOR': 'local', 'FLEET_LOCAL_BOX': 'fixture',
               'ISSUE_WAVE_STATE': str(root), 'FLEET_ANCHOR_STATE': str(root),
               'FLEET_COORDINATOR': 'first', 'FLEET_LOCK_WAIT': '10'}
        env.pop('FLEET_BOXES', None)
        env.pop('FLEET_BOX_CORRECTNESS_SLOTS', None)

        def run(*args, expected=0, script=SCRIPT, **extra):
            result = subprocess.run(['bash', str(script), *args], env={**env, **extra},
                                    text=True, capture_output=True, timeout=20)
            assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
            return result.stdout, result.stderr

        def change(action, data, expected=0, script=SCRIPT, **extra):
            with tempfile.NamedTemporaryFile(mode='w', dir=root, suffix='.input') as stream:
                json.dump(data, stream)
                stream.flush()
                return run('execution', action, stream.name, expected=expected, script=script, **extra)

        def request(identity, host, kind='measurement'):
            return dict(request_id=identity, wave='wave', worker=identity, transport='subagent',
                        issue='repo#395', purpose='fixture', agent_host='mac', execution_host=host,
                        repository='owner/repo', requested_revision='origin/main', kind=kind)

        def records():
            return {r['request_id']: r for r in json.loads(run('execution', 'list')[0])}

        run('claim')
        # The default roster, unset and exported alike, keeps passing, with no warning.
        out, err = change('reserve', request('measure-rog', 'rog-nv-linux'))
        assert 'WARNING' not in err, err
        out, err = change('reserve', request('measure-minix', 'minix-amd-linux'),
                          FLEET_BOXES='mac-studio rog-nv-linux minix-amd-linux tuf-amd-linux')
        assert 'WARNING' not in err, err
        # Two aliases of rog: the refusal names both entries and the box, whichever alias is asked for,
        # for reserve, run and dispatch alike, and nothing is written.
        split = 'mac-studio rog-nv-linux rog-nv-wsl minix-amd-linux'
        want = 'FLEET_BOXES lists rog-nv-linux and rog-nv-wsl, two aliases of the one box rog'
        for action, host in [('reserve', 'rog-nv-wsl'), ('run', 'rog-nv-wsl'), ('reserve', 'mac-studio')]:
            out, err = change(action, request('split-' + action + '-' + host, host), expected=1, FLEET_BOXES=split)
            assert want in err, err
        change('reserve', request('check-mac', 'mac-studio', 'correctness'))
        out, err = change('dispatch', dict(request_id='check-mac', evidence='fixture dispatch'),
                          expected=1, FLEET_BOXES=split)
        assert want in err, err
        # The Windows host and its LAN route, the box's own name, and a case variant are one box too.
        for roster, pair in [('mac-studio minix-amd-win minix-lan', 'minix-amd-win and minix-lan, two aliases of the one box minix'),
                             ('mac-studio tuf tuf-amd-linux', 'tuf and tuf-amd-linux, two aliases of the one box tuf'),
                             ('mac-studio ROG-NV-WSL rog-nv-linux', 'ROG-NV-WSL and rog-nv-linux, two aliases of the one box rog'),
                             ('mac-studio Mac-Studio', 'mac-studio and Mac-Studio, two aliases of the one box mac-studio')]:
            out, err = change('reserve', request('split-case', 'mac-studio', 'correctness'), expected=1, FLEET_BOXES=roster)
            assert pair in err, (roster, err)
        assert not [identity for identity in records() if identity.startswith('split-')], records()
        # A repeated identical entry is the same entry, not two aliases.
        change('reserve', request('check-mac', 'mac-studio', 'correctness'), FLEET_BOXES='mac-studio mac-studio rog-nv-linux minix-amd-linux')
        # Reads and conclusions stay available under the split roster.
        run('execution', 'list', FLEET_BOXES=split)
        change('conclude', dict(request_id='measure-rog', verdict='not-launched', log='/logs/rog',
                                evidence='fixture never dispatched'), FLEET_BOXES=split)
        assert records()['measure-rog']['state'] == 'concluded'
        # Reached through a skills symlink, as installed (~/.claude/skills/issue-wave -> the
        # checkout's issue-wave), the map is still found: `..` must leave the symlink's target.
        skills = root / 'skills'
        skills.mkdir()
        (skills / 'issue-wave').symlink_to(SCRIPT.resolve().parent.parent)
        out, err = change('reserve', request('linked-split', 'rog-nv-wsl'), expected=1, FLEET_BOXES=split,
                          script=skills / 'issue-wave' / 'scripts' / 'fleet-worker.sh')
        assert want in err and 'WARNING' not in err, err
        # A checkout with no wake-lab.sh degrades loudly: one warning, and the roster check keeps to
        # exact entries up to case, so the split roster is admitted as it was before #395.
        bare = root / 'bare'
        (bare / 'issue-wave' / 'scripts').mkdir(parents=True)
        for name in ['fleet-worker.sh', 'fleet-execution.py']:
            shutil.copy(SCRIPT.with_name(name), bare / 'issue-wave' / 'scripts' / name)
        copied = bare / 'issue-wave' / 'scripts' / 'fleet-worker.sh'
        with tempfile.NamedTemporaryFile(mode='w', dir=root, suffix='.input') as stream:
            json.dump(request('bare-wsl', 'rog-nv-wsl'), stream)
            stream.flush()
            out, err = run('execution', 'reserve', stream.name, script=copied, FLEET_BOXES=split)
            assert 'EXECUTION WARNING: no endpoint map' in err and 'wake-lab.sh is missing' in err, err
            # A wake-lab.sh that refuses its own map refuses the reservation instead.
            (bare / 'scripts').mkdir()
            (bare / 'scripts' / 'wake-lab.sh').write_text('echo "wake-lab.sh: the endpoint map is inconsistent" >&2; exit 1\n')
            out, err = run('execution', 'reserve', stream.name, script=copied, expected=1,
                           FLEET_BOXES='mac-studio')
            assert 'the endpoint map is inconsistent' in err and 'endpoint-map failed' in err, err
        assert 'bare-wsl' in records()
        # The helper refuses a map naming one alias on two rows, rather than picking a box.
        with tempfile.TemporaryDirectory(prefix='fleet-map-') as state:
            result = subprocess.run(['python3', str(SCRIPT.with_name('fleet-execution.py')), state, 'reserve',
                                     'owner', 'token', json.dumps(request('bad-map', 'mac-studio')), 'mac-studio',
                                     '', 'rog rog-nv-linux\nnova rog-nv-linux'], text=True, capture_output=True)
            assert result.returncode == 1 and 'puts rog-nv-linux on both rog and nova' in result.stderr, result
        print('PASS: one roster entry per physical box, from the endpoint map; a missing map degrades loudly')


one_entry_per_box()

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
