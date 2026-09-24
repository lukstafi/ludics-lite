#!/usr/bin/env python3
"""Isolated bootstrap safety checks; never installs packages or contacts the fleet."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('install-linux.sh').resolve()


class BootstrapSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_shell(self, body, success=True):
        result = subprocess.run(
            ['bash', '-c', 'source "$1"; cd "$2"; ' + body, 'test', str(SCRIPT), str(self.root)],
            text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_import_has_no_install_side_effects(self):
        self.run_shell(':')
        self.assertEqual(list(self.root.iterdir()), [])

    def test_skill_link_rerun(self):
        self.run_shell('mkdir src; link_skill "$PWD/src" "$PWD/link"; link_skill "$PWD/src" "$PWD/link"')
        self.assertTrue((self.root / 'link').is_symlink())
        self.assertEqual(list((self.root / 'src').iterdir()), [])

    def test_real_skill_directory_preserved(self):
        self.run_shell('mkdir src link; echo KEEP > link/local; link_skill "$PWD/src" "$PWD/link"', False)
        self.assertEqual((self.root / 'link/local').read_text(), 'KEEP\n')

    def test_wrong_symlink_preserved(self):
        self.run_shell('ln -s missing link; link_skill "$PWD/src" "$PWD/link"', False)
        self.assertEqual(os.readlink(self.root / 'link'), 'missing')

    def test_new_startup_and_idempotence(self):
        self.run_shell("source_at_start rc 'export FLEET_LOCAL_BOX=native'; source_at_start rc 'export FLEET_LOCAL_BOX=native'")
        self.assertEqual((self.root / 'rc').read_text(), 'export FLEET_LOCAL_BOX=native\n')
        self.assertEqual(list(self.root.glob('*.fleet-backup.*')), [])

    def test_startup_precedes_early_return_and_backs_up(self):
        (self.root / 'rc').write_text('return\n')
        (self.root / 'rc').chmod(0o640)
        self.run_shell("source_at_start rc 'export FLEET_LOCAL_BOX=native'; source_at_start rc 'export FLEET_LOCAL_BOX=native'; source rc; test \"$FLEET_LOCAL_BOX\" = native")
        backups = list(self.root.glob('rc.fleet-backup.*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), 'return\n')
        self.assertEqual((self.root / 'rc').stat().st_mode & 0o777, 0o640)

    def test_startup_symlink_preserved(self):
        self.run_shell("echo KEEP > real; ln -s real rc; source_at_start rc 'source env'", False)
        self.assertEqual((self.root / 'real').read_text(), 'KEEP\n')

    def test_append_line_ends_the_file_once(self):
        (self.root / 'env.sh').write_text('export A=1')
        self.run_shell("append_line env.sh '. token'; append_line env.sh '. token'")
        self.assertEqual((self.root / 'env.sh').read_text(), 'export A=1\n. token\n')

    def test_append_line_moves_an_earlier_copy_last(self):
        (self.root / 'env.sh').write_text('. token\nexport GH_TOKEN=stale\n')
        (self.root / 'env.sh').chmod(0o640)
        self.run_shell("append_line env.sh '. token'")
        self.assertEqual((self.root / 'env.sh').read_text(), 'export GH_TOKEN=stale\n. token\n')
        self.assertEqual((self.root / 'env.sh').stat().st_mode & 0o777, 0o640)

    def test_startup_line_below_an_early_return_moves_first(self):
        (self.root / 'rc').write_text('return\nsource env\n')
        self.run_shell("source_at_start rc 'source env'")
        self.assertEqual((self.root / 'rc').read_text(), 'source env\nreturn\n')

    def test_append_line_never_follows_a_symlink_or_creates(self):
        self.run_shell("echo KEEP > real; ln -s real env.sh; append_line env.sh '. token'")
        self.assertEqual((self.root / 'real').read_text(), 'KEEP\n')
        self.run_shell("append_line missing '. token'", False)
        self.assertFalse((self.root / 'missing').exists())

    def test_wrong_repository_preserved(self):
        self.run_shell('git init -q repo; git -C repo remote add origin https://github.com/other/repo.git; clone_if_missing lukstafi/ludics-lite "$PWD/repo"', False)
        self.assertTrue((self.root / 'repo/.git').is_dir())

    def test_dirty_repository_preserved(self):
        self.run_shell('git init -q repo; git -C repo remote add origin https://github.com/lukstafi/ludics-lite.git; echo KEEP > repo/local; clone_if_missing lukstafi/ludics-lite "$PWD/repo"')
        self.assertEqual((self.root / 'repo/local').read_text(), 'KEEP\n')

    def test_download_failure_does_not_execute(self):
        self.run_shell('scratch=$PWD; curl() { return 22; }; installer nonexistent-fleet-test https://example.invalid bash', False)
        self.assertEqual(list(self.root.iterdir()), [])

    def make_console_key(self):
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f',
                        str(self.root / 'console')], check=True, capture_output=True)
        return (self.root / 'console.pub').read_text().strip()

    def test_console_key_rerun(self):
        key = self.make_console_key()
        self.run_shell('key=$(cat console.pub); authorize_console_key "$key" "$PWD/ssh"; authorize_console_key "$key" "$PWD/ssh"')
        authorized = self.root / 'ssh/authorized_keys'
        self.assertEqual(authorized.read_text(), key + '\n')
        self.assertEqual(authorized.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / 'ssh').stat().st_mode & 0o777, 0o700)

    def test_existing_key_restrictions_preserved(self):
        key = self.make_console_key()
        (self.root / 'ssh').mkdir()
        authorized = self.root / 'ssh/authorized_keys'
        original = 'restrict ' + key  # Deliberately no trailing newline.
        authorized.write_text(original)
        self.run_shell('key=$(cat console.pub); authorize_console_key "$key" "$PWD/ssh"')
        self.assertEqual(authorized.read_text(), original)

    def test_console_key_append_preserves_existing_file(self):
        key = self.make_console_key()
        (self.root / 'ssh').mkdir()
        authorized = self.root / 'ssh/authorized_keys'
        authorized.write_text('# existing configuration')
        self.run_shell('key=$(cat console.pub); authorize_console_key "$key" "$PWD/ssh"')
        self.assertEqual(authorized.read_text(), '# existing configuration\n' + key + '\n')

    def test_invalid_console_key_preserves_authorization(self):
        (self.root / 'ssh').mkdir()
        authorized = self.root / 'ssh/authorized_keys'
        authorized.write_text('# KEEP\n')
        self.run_shell('authorize_console_key "ssh-ed25519 invalid" "$PWD/ssh"', False)
        self.assertEqual(authorized.read_text(), '# KEEP\n')
        self.assertEqual(list((self.root / 'ssh').glob('key-check.*')), [])

    def test_authorized_keys_symlink_refused(self):
        self.make_console_key()
        self.run_shell('mkdir ssh; echo KEEP > real; ln -s ../real ssh/authorized_keys; key=$(cat console.pub); authorize_console_key "$key" "$PWD/ssh"', False)
        self.assertEqual((self.root / 'real').read_text(), 'KEEP\n')

    def test_inhibit_rule_names_user_and_action(self):
        rule = self.run_shell('inhibit_rule lukstafi').stdout
        self.assertIn('subject.user == "lukstafi"', rule)
        self.assertIn('action.id == "org.freedesktop.login1.inhibit-block-sleep"', rule)

    def test_inhibit_rule_refuses_injected_user(self):
        self.run_shell('inhibit_rule \'x" || true || "\'', False)

    def test_inhibit_grant_installs_only_on_difference(self):
        stub = 'scratch=$PWD; sudo() { echo "$*" >> calls; [ "$1" != cmp ] || return "$CMP_RC"; }; id() { echo lukstafi; }; '
        self.run_shell(stub + 'CMP_RC=0 install_inhibit_grant')
        self.assertNotIn('install -m', (self.root / 'calls').read_text())
        self.run_shell(stub + 'CMP_RC=1 install_inhibit_grant')
        self.assertIn('install -m 644', (self.root / 'calls').read_text())

    def test_lid_dropin_ignores_lid_on_external_power_only(self):
        conf = self.run_shell('lid_dropin').stdout
        self.assertIn('[Login]\nHandleLidSwitchExternalPower=ignore\n', conf)
        self.assertNotIn('HandleLidSwitch=', conf)

    def test_has_lid_follows_the_acpi_button(self):
        self.run_shell('mkdir -p lid/LID0; FLEET_LID_GLOB="$PWD/lid/*" has_lid')
        self.run_shell('FLEET_LID_GLOB="$PWD/nolid/*" has_lid', False)

    def test_lid_dropin_installs_and_reloads_only_on_difference(self):
        stub = 'scratch=$PWD; sudo() { echo "$*" >> calls; [ "$1" != cmp ] || return "$CMP_RC"; }; '
        self.run_shell(stub + 'CMP_RC=0 install_lid_dropin')
        self.assertNotIn('reload', (self.root / 'calls').read_text())
        self.run_shell(stub + 'CMP_RC=1 install_lid_dropin')
        calls = (self.root / 'calls').read_text()
        self.assertIn('install -D -m 644', calls)
        self.assertIn('systemctl reload systemd-logind', calls)

    def test_wake_timer_wakes_the_system_at_the_given_time(self):
        timer = self.run_shell('wake_timer 06:58').stdout
        self.assertIn('[Timer]\nOnCalendar=*-*-* 06:58:00\nWakeSystem=true\n', timer)
        self.assertIn('Persistent=false\n', timer)
        self.assertIn('[Install]\nWantedBy=timers.target\n', timer)

    def test_wake_timer_refuses_a_malformed_time(self):
        for bad in ['7:00', '24:00', '06:60', '06:58; rm -rf /', '']:
            self.run_shell('wake_timer ' + repr(bad), False)

    def test_wake_service_runs_nothing(self):
        service = self.run_shell('wake_service').stdout
        self.assertIn('[Service]\nType=oneshot\nExecStart=/bin/true\n', service)

    def test_wake_timer_installs_and_reloads_only_on_difference(self):
        stub = 'scratch=$PWD; sudo() { echo "$*" >> calls; [ "$1" != cmp ] || return "$CMP_RC"; }; '
        self.run_shell(stub + 'CMP_RC=0 install_wake_timer 06:58')
        calls = (self.root / 'calls').read_text()
        self.assertNotIn('install -D', calls)
        self.assertNotIn('daemon-reload', calls)
        self.assertIn('systemctl enable --now fleet-sweep-wake.timer', calls)
        (self.root / 'calls').unlink()
        self.run_shell(stub + 'CMP_RC=1 install_wake_timer 06:58')
        calls = (self.root / 'calls').read_text()
        self.assertIn('install -D -m 644 ' + str(self.root) + '/fleet-sweep-wake.timer /etc/systemd/system/fleet-sweep-wake.timer', calls)
        self.assertIn('install -D -m 644 ' + str(self.root) + '/fleet-sweep-wake.service /etc/systemd/system/fleet-sweep-wake.service', calls)
        self.assertLess(calls.index('daemon-reload'), calls.index('enable --now'))
        self.assertIn('OnCalendar=*-*-* 06:58:00', (self.root / 'fleet-sweep-wake.timer').read_text())

    def test_wake_timer_install_refuses_a_malformed_time_before_sudo(self):
        stub = 'scratch=$PWD; sudo() { echo "$*" >> calls; }; '
        self.run_shell(stub + 'install_wake_timer 7am', False)
        self.assertFalse((self.root / 'calls').exists())

    def test_wake_timer_default_precedes_the_sweep(self):
        self.assertEqual(self.run_shell('echo "$DEFAULT_WAKE_TIME"').stdout, '06:55\n')
        self.run_shell('valid_wake_time "$DEFAULT_WAKE_TIME"')

    def test_wake_timer_only_installs_the_default_or_a_given_time(self):
        stub = 'uname() { echo Linux; }; sudo() { echo "$*" >> calls; [ "$1" != cmp ] || return 1; }; '
        self.run_shell(stub + 'wake_timer_only; cp "$scratch/fleet-sweep-wake.timer" default.timer')
        self.assertIn('OnCalendar=*-*-* 06:55:00', (self.root / 'default.timer').read_text())
        self.assertIn('systemctl enable --now fleet-sweep-wake.timer', (self.root / 'calls').read_text())
        self.run_shell(stub + 'wake_timer_only 06:40; cp "$scratch/fleet-sweep-wake.timer" given.timer')
        self.assertIn('OnCalendar=*-*-* 06:40:00', (self.root / 'given.timer').read_text())

    def test_wake_timer_only_refuses_before_sudo(self):
        stub = 'uname() { echo Linux; }; sudo() { echo "$*" >> calls; }; '
        self.run_shell(stub + 'wake_timer_only 6am', False)
        self.run_shell(stub + 'wake_timer_only 06:55 extra', False)
        self.run_shell('sudo() { echo "$*" >> calls; }; uname() { echo Darwin; }; wake_timer_only', False)
        self.assertFalse((self.root / 'calls').exists())

    def test_librocwmma_pin_blocks_the_distro_package(self):
        pin = self.run_shell('librocwmma_pin').stdout
        self.assertIn('Package: librocwmma-dev\nPin: release *\nPin-Priority: -1\n', pin)

    ROCWMMA_STUB = ('scratch=$PWD; sudo() { echo "$*" >> calls; [ "$1" != cmp ] || return "$CMP_RC"; }; '
                    'git() { echo "git $*" >> calls; d=${@: -1}; mkdir -p "$d/library/include/rocwmma/internal"; '
                    'touch "$d/library/include/rocwmma/rocwmma.hpp"; [ -n "${PARTIAL-}" ] || '
                    'touch "$d/library/include/rocwmma/internal/types.hpp"; }; ')

    def test_rocwmma_installs_the_full_upstream_tree_and_pins_the_package(self):
        self.run_shell(self.ROCWMMA_STUB + 'CMP_RC=1 install_rocwmma')
        calls = (self.root / 'calls').read_text()
        self.assertIn('--branch rocm-7.1.0 https://github.com/ROCm/rocWMMA.git', calls)
        self.assertIn('install -D -m 644 ' + str(self.root) + '/no-librocwmma-dev /etc/apt/preferences.d/no-librocwmma-dev', calls)
        self.assertIn('cp -r ' + str(self.root) + '/rocWMMA/library/include/rocwmma/. /usr/include/rocwmma/', calls)

    def test_rocwmma_pin_rewritten_only_on_difference(self):
        self.run_shell(self.ROCWMMA_STUB + 'CMP_RC=0 install_rocwmma')
        self.assertNotIn('install -D -m 644', (self.root / 'calls').read_text())

    def test_rocwmma_refuses_a_tree_without_internal_before_copying(self):
        self.run_shell(self.ROCWMMA_STUB + 'PARTIAL=1 CMP_RC=1 install_rocwmma', False)
        calls = (self.root / 'calls').read_text()
        self.assertNotIn('/usr/include/rocwmma', calls)
        self.assertNotIn('preferences.d', calls)

    def test_unknown_option(self):
        result = subprocess.run(['bash', str(SCRIPT), '--bogus'], capture_output=True)
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
