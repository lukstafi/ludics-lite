#!/usr/bin/env python3
"""SSH mesh mutation safety; isolated files and generated disposable public keys."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('peers', Path(__file__).with_name('fleet-peers.py'))
peers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(peers)


class MeshSafety(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys_tmp = tempfile.TemporaryDirectory()
        cls.keys = []
        for n in range(4):
            path = Path(cls.keys_tmp.name) / str(n)
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(path)], check=True)
            cls.keys.append(path.with_suffix('.pub').read_text().strip())

    @classmethod
    def tearDownClass(cls):
        cls.keys_tmp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sshdir = Path(self.tmp.name) / 'ssh'
        self.own = dict(host='hub', user='alice', key=self.keys[0], host_key=self.keys[1], identity='id_ed25519')
        self.other = dict(host='worker', user='bob', key=self.keys[2], host_key=self.keys[3], identity='id_ed25519_fleet')
        self.roster = [self.own, self.other]

    def apply(self):
        return peers.install_mesh(self.own, self.roster, self.sshdir)

    def test_rerun_preserves_existing_config_and_authorization(self):
        self.sshdir.mkdir()
        (self.sshdir / 'authorized_keys').write_text('# console key\n' + self.keys[0])
        original = 'Host unrelated\n  User carol\n'
        (self.sshdir / 'config').write_text(original)
        self.apply()
        contents = {p.name: p.read_bytes() for p in self.sshdir.iterdir() if p.is_file()}
        self.apply()
        self.assertEqual(contents, {p.name: p.read_bytes() for p in self.sshdir.iterdir() if p.is_file()})
        self.assertIn(original, (self.sshdir / 'config').read_text())
        self.assertIn(self.keys[0], (self.sshdir / 'authorized_keys').read_text())
        self.assertIn(self.keys[2], (self.sshdir / 'authorized_keys').read_text())
        self.assertNotIn('macbook-air', (self.sshdir / 'fleet.conf').read_text())
        self.assertEqual((self.sshdir / 'authorized_keys').stat().st_mode & 0o777, 0o600)
        self.assertIn('User bob', (self.sshdir / 'fleet.conf').read_text())
        self.assertTrue((self.sshdir / 'fleet.conf').read_text().endswith('Host *\n'))

    def test_rerun_tightens_a_loosened_mode_on_unchanged_content(self):
        self.apply()
        (self.sshdir / 'config').chmod(0o664)
        self.apply()
        self.assertEqual((self.sshdir / 'config').stat().st_mode & 0o777, 0o600)

    def test_default_key_without_public_half_refused(self):
        home = Path(self.tmp.name) / 'home'
        (home / '.ssh').mkdir(parents=True)
        (home / '.ssh/id_ed25519').write_text('private')
        (home / '.ssh/id_ed25519').chmod(0o600)
        with patch.object(peers.Path, 'home', return_value=home):
            with self.assertRaisesRegex(RuntimeError, 'Missing public key'):
                peers.collect('hub', True, True)

    def test_default_key_readable_by_others_refused(self):
        home = Path(self.tmp.name) / 'home'
        (home / '.ssh').mkdir(parents=True)
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(home / '.ssh/id_ed25519')], check=True)
        (home / '.ssh/id_ed25519').chmod(0o644)
        with patch.object(peers.Path, 'home', return_value=home):
            with self.assertRaisesRegex(RuntimeError, 'readable by others'):
                peers.collect('hub', True, True)

    def test_default_key_with_a_stale_public_half_refused(self):
        home = Path(self.tmp.name) / 'home'
        (home / '.ssh').mkdir(parents=True)
        for name in ('id_ed25519', 'other'):
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', 'pw', '-f', str(home / '.ssh' / name)], check=True)
        (home / '.ssh/other.pub').replace(home / '.ssh/id_ed25519.pub')
        with patch.object(peers.Path, 'home', return_value=home):
            with self.assertRaisesRegex(RuntimeError, 'Public/private key mismatch'):
                peers.collect('hub', True, True)

    def test_restricted_existing_key_not_broadened(self):
        original = 'restrict,from="100.0.0.1" ' + self.keys[2]
        self.assertEqual(peers.add_authorized(original, [self.keys[2]]), original)

    def test_changed_host_key_refuses_before_any_grants(self):
        self.sshdir.mkdir()
        (self.sshdir / 'known_hosts').write_text('worker ' + self.keys[1] + '\n')
        with self.assertRaisesRegex(RuntimeError, 'Host key changed'):
            self.apply()
        self.assertFalse((self.sshdir / 'authorized_keys').exists())
        self.assertFalse((self.sshdir / '.fleet-peers.lock').exists())

    def test_hashed_changed_host_key_refused(self):
        self.sshdir.mkdir()
        path = self.sshdir / 'known_hosts'
        path.write_text('worker ' + self.keys[1] + '\n')
        subprocess.run(['ssh-keygen', '-H', '-f', str(path)], check=True, capture_output=True)
        with self.assertRaisesRegex(RuntimeError, 'Host key changed'):
            self.apply()

    def test_invalid_key_before_mutation(self):
        self.other['key'] = 'ssh-ed25519 invalid'
        with self.assertRaises(subprocess.CalledProcessError):
            self.apply()
        self.assertFalse(self.sshdir.exists())

    def test_symlink_preserves_target(self):
        self.sshdir.mkdir()
        target = Path(self.tmp.name) / 'target'
        target.write_text('KEEP')
        (self.sshdir / 'authorized_keys').symlink_to(target)
        with self.assertRaisesRegex(RuntimeError, 'nonregular'):
            self.apply()
        self.assertEqual(target.read_text(), 'KEEP')

    def test_concurrent_writer_refused(self):
        self.sshdir.mkdir()
        (self.sshdir / '.fleet-peers.lock').mkdir()
        with self.assertRaises(FileExistsError):
            self.apply()
        self.assertTrue((self.sshdir / '.fleet-peers.lock').exists())

    def test_private_files_never_distributed(self):
        self.apply()
        self.assertEqual(set(p.name for p in self.sshdir.iterdir()),
                         {'authorized_keys', 'fleet.conf', 'fleet_known_hosts', 'config'})
        for path in self.sshdir.iterdir():
            self.assertNotIn('PRIVATE KEY', path.read_text())

    def test_all_directions_except_self(self):
        with patch.object(peers, 'run', return_value='bob') as call:
            result = peers.verify_mesh(self.own, self.roster)
        self.assertEqual(result, [dict(ok=True, **{'from': 'hub', 'to': 'worker'})])
        self.assertEqual(call.call_count, 1)
        self.assertIn('BatchMode=yes', call.call_args.args[0])

    def test_wrong_remote_user_reported(self):
        with patch.object(peers, 'run', return_value='wrong'):
            result = peers.verify_mesh(self.own, self.roster)
        self.assertFalse(result[0]['ok'])

    def test_air_cannot_be_added_to_mesh(self):
        with patch('sys.argv', ['fleet-peers.py', '--peer', 'macbook-air']), \
             patch.object(peers, 'run', return_value='{"Self":{"DNSName":"mac-studio.example.ts.net."}}'):
            with self.assertRaises(SystemExit) as error:
                peers.main()
        self.assertEqual(error.exception.code, 2)

    def test_local_sentinel_cannot_be_a_peer(self):
        with patch('sys.argv', ['fleet-peers.py', '--peer', 'mac-studio', '--peer', 'local']), \
             patch.object(peers, 'run', return_value='{"Self":{"DNSName":"mac-studio.example.ts.net."}}'), \
             patch.object(peers, 'invoke') as invoke:
            with self.assertRaises(SystemExit) as error:
                peers.main()
        self.assertEqual(error.exception.code, 2)
        invoke.assert_not_called()

    def test_custom_roster_must_include_the_coordinator(self):
        with patch('sys.argv', ['fleet-peers.py', '--peer', 'rog-nv-linux', '--peer', 'minix-amd-linux']), \
             patch.object(peers, 'run', return_value='{"Self":{"DNSName":"mac-studio.example.ts.net."}}'), \
             patch.object(peers, 'invoke') as invoke:
            with self.assertRaises(SystemExit) as error:
                peers.main()
        self.assertEqual(error.exception.code, 2)
        invoke.assert_not_called()


if __name__ == '__main__':
    unittest.main()
