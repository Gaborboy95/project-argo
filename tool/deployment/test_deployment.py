"""No radio mutations: exercise actual release transactions with an injected manager."""
import configparser
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import MagicMock, patch

loader = importlib.machinery.SourceFileLoader('argoctl', str(Path(__file__).with_name('argoctl')))
spec = importlib.util.spec_from_loader(loader.name, loader)
a = importlib.util.module_from_spec(spec)
loader.exec_module(a)


class Manager(a.Deployment):
    def __init__(self, home):
        super().__init__(home)
        self.running = set()
        self.fail_start = False
        self.uncertain = False
        self.operations = []

    def status(self, unit, timeout=125):
        return {'ActiveState': 'active' if unit in self.running else 'inactive',
                'Result': 'failure' if self.uncertain and unit in a.UNITS else 'success'}

    def systemctl(self, *args, check=True, timeout=125):
        self.operations.append(args)
        if args[0] == 'stop':
            self.running.clear()
        if args[0] == 'start':
            if self.fail_start:
                self.fail_start = False
                raise subprocess.CalledProcessError(1, 'start')
            self.running.update(args[1:])
            if 'argo.target' in args:
                self.running.update(self.release_units(self.current.resolve()))
        return subprocess.CompletedProcess(args, 0, '', '')


class DeploymentTest(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(a.os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        # The developer shell may itself inherit a systemd invocation. Tests
        # explicitly opt in to managed readiness instead of observing that unit.
        a.os.environ.pop('INVOCATION_ID', None)
        processes = patch.object(a, 'program_pids', return_value=set())
        processes.start()
        self.addCleanup(processes.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Manager(Path(self.tmp.name))
        ihs = self.d.home / 'ihs'
        for f in a.IHS_FILES:
            p = ihs / f; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(f)
        a.save(self.d.config / 'deployment.json', {'ihs_prefix': str(ihs)})
        self.source = self.d.home / 'bundle'
        for f in a.REQUIRED:
            p = self.source / f; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(f)
        (self.source / 'bin/argo-projectiond').chmod(0o755)
        a.save(self.source / 'argo-release.json', {
            'schema': 1, 'ipc': 6, 'managed_control': 1,
            'ihs_sha256': self.d.ihs()[1],
            'sha256': {f: a.digest(self.source / f) for f in a.REQUIRED}})
        self.first = self.d.stage(self.source, 'first')
        self.second = self.d.stage(self.source, 'second')
        self.d.select(self.first)
        self.d.operations.clear()

    def test_camera_assets_are_optional_but_must_form_a_versioned_pair(self):
        self.d.validate(self.source)  # Existing camera-less releases stay valid.
        manifest = a.read(self.source / 'argo-release.json')
        for file in ('bin/argo-camerad', 'lib/libargo_camera_view.so'):
            path = self.source / file
            path.write_text(file)
            path.chmod(0o755)
            manifest['sha256'][file] = a.digest(path)
            a.save(self.source / 'argo-release.json', manifest)
            with self.assertRaisesRegex(ValueError, 'Camera'):
                self.d.validate(self.source)
        manifest['camera_contract'] = 1
        a.save(self.source / 'argo-release.json', manifest)
        self.d.validate(self.source)
        (self.source / 'bin/argo-camerad').write_text('changed binary')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            self.d.validate(self.source)

    def carplay_bundle(self):
        manifest = a.read(self.source / 'argo-release.json')
        for name in ('argo-carplayd', 'argo-carplayctl'):
            relative = 'bin/' + name
            path = self.source / relative
            path.write_text(name)
            path.chmod(0o755)
            manifest['sha256'][relative] = a.digest(path)
        manifest.update(carplay_control=1, carplay_scope='diagnostics-only')
        a.save(self.source / 'argo-release.json', manifest)
        return self.d.stage(self.source, 'carplay')

    def test_optional_carplay_requires_a_matched_pair_and_contract(self):
        bundle = self.carplay_bundle()
        self.d.validate(bundle)
        manifest = a.read(bundle / 'argo-release.json')
        manifest['carplay_control'] = 2
        a.save(bundle / 'argo-release.json', manifest)
        with self.assertRaisesRegex(ValueError, 'CarPlay diagnostics'):
            self.d.validate(bundle)
        manifest['carplay_control'] = 1
        a.save(bundle / 'argo-release.json', manifest)
        (bundle / 'bin/argo-carplayctl').unlink()
        with self.assertRaisesRegex(ValueError, 'CarPlay diagnostics'):
            self.d.validate(bundle)
        self.d.validate(self.first)

    def test_carplay_service_follows_release_selection_and_old_release_rollback(self):
        bundle = self.carplay_bundle()
        self.d.running = {'argo.target', *a.UNITS}
        self.d.select(bundle)
        self.assertEqual(self.d.running, {'argo.target', *a.ALL_UNITS})
        self.d.select(self.first)
        self.assertEqual(self.d.running, {'argo.target', *a.UNITS})
        self.d.select(bundle)
        self.d.fail_start = True
        with self.assertRaisesRegex(RuntimeError, 'previous selection restored'):
            self.d.select(self.first)
        self.assertEqual(self.d.running, {'argo.target', *a.ALL_UNITS})
        self.assertEqual(self.d.current.resolve(), bundle)

    def test_carplay_only_downgrade_stops_without_an_empty_start_command(self):
        bundle = self.carplay_bundle()
        self.d.select(bundle)
        self.d.running = {a.CARPLAY_UNIT}
        self.d.operations.clear()
        self.d.select(self.first)
        self.assertEqual(self.d.current.resolve(), self.first)
        self.assertEqual(self.d.running, set())
        self.assertFalse(any(command[0] == 'start' for command in self.d.operations))

    def test_carplay_readiness_rejects_wrong_shape_and_contract_then_recovers(self):
        replies = [b'[]\n', b'{"contract":true}\n',
                   b'{"contract":1,"implementation":"native-carplay","session_validated":true}\n',
                   b'{"contract":1,"implementation":"diagnostics-only","session_validated":false}\n']
        peers = []
        for reply in replies:
            peer = MagicMock()
            peer.__enter__.return_value = peer
            peer.recv.return_value = reply
            peers.append(peer)
        with patch.object(a.socket, 'socket', side_effect=peers), \
                patch.object(self.d, 'runtime', return_value=self.d.home), \
                patch.object(a.time, 'sleep'):
            self.d.ready('carplay')
        self.assertTrue(all(peer.sendall.call_args.args == (b'status\n',) for peer in peers))

    def test_carplay_readiness_deadline_bounds_a_dripping_response(self):
        peer = MagicMock()
        peer.__enter__.return_value = peer
        peer.recv.return_value = b' '
        with patch.object(a.socket, 'socket', return_value=peer), \
                patch.object(self.d, 'runtime', return_value=self.d.home), \
                patch.object(a.time, 'sleep'), \
                patch.object(a.time, 'monotonic', side_effect=[0, 0, 1, 21, 21]):
            with self.assertRaisesRegex(RuntimeError, 'readiness probe'):
                self.d.ready('carplay')
        self.assertEqual(peer.recv.call_count, 1)

    def test_wired_carplay_configuration_is_typed_and_contract_gated(self):
        config = dict(enabled=True, width=1280, height=720, width_mm=200,
                      height_mm=112, audio_sink='bluez_output.fixture.1')
        manifest = dict(carplay_wired=1, projection_media_contract=1)
        self.assertEqual(a.carplay_arguments(config, manifest),
                         ['--wired', '1280', '720', '200', '112', '--audio', 'bluez_output.fixture.1'])
        self.assertEqual(a.carplay_arguments(dict(config, usb_lease=True), manifest)[-1], '--usb-lease')
        self.assertEqual(a.carplay_arguments(dict(config, audio_source='alsa_input.fixture', usb_lease=True), manifest)[-3:], ['--microphone', 'alsa_input.fixture', '--usb-lease'])
        with self.assertRaises(ValueError):
            a.carplay_arguments(dict(config, audio_source='source;command'), manifest)
        no_output = dict(config, audio_source='source')
        del no_output['audio_sink']
        with self.assertRaises(ValueError):
            a.carplay_arguments(no_output, manifest)
        for changes in [dict(width=True), dict(height=99999), dict(enabled='true'),
                        dict(audio_sink='speaker; command'), dict(raw_command='anything'), dict(usb_lease='yes')]:
            with self.assertRaises(ValueError):
                a.carplay_arguments(dict(config, **changes), manifest)
        with self.assertRaises(ValueError):
            a.carplay_arguments(config, {})
        self.assertEqual(a.carplay_arguments(dict(enabled=False), {}), [])

    def test_carplay_launch_is_unprivileged_isolated_and_gates_health_ui(self):
        bundle = self.carplay_bundle()
        self.d.select(bundle)
        with patch.dict(a.os.environ, {'WAYLAND_DISPLAY': 'test',
                'DBUS_SESSION_BUS_ADDRESS': 'unix:path=test',
                'XDG_RUNTIME_DIR': str(self.d.home),
                'ARGO_ANDROID_AUTO_KEY_FILE': '/must-not-leak',
                'ARGO_LIVI_LINK_ADDRESS': '192.0.2.2'}), patch.object(a.os, 'execve') as execute:
            self.d.launch('carplay', managed=False)
            binary, command, environment = execute.call_args.args
            self.assertEqual(binary, str(bundle / 'bin/argo-carplayd'))
            self.assertEqual(command, [binary])
            self.assertEqual(environment['ARGO_CARPLAY_DIAGNOSTICS'], '1')
            self.assertNotIn('ARGO_ANDROID_AUTO_KEY_FILE', environment)
            self.assertNotIn('ARGO_LIVI_LINK_ADDRESS', environment)
        self.d.select(self.first)
        with patch.dict(a.os.environ, {'WAYLAND_DISPLAY': 'test',
                'DBUS_SESSION_BUS_ADDRESS': 'unix:path=test'}):
            with self.assertRaisesRegex(ValueError, 'no CarPlay'):
                self.d.launch('carplay', managed=False)

    def test_external_camera_mode_and_legacy_rollback(self):
        manifest = a.read(self.source / 'argo-release.json')
        view = self.source / 'lib/libargo_camera_view.so'
        view.write_text('external native presentation')
        manifest['sha256']['lib/libargo_camera_view.so'] = a.digest(view)
        manifest.update(camera_mode='external', camera_view_contract=2,
                        camera_api={'major': 1, 'min_minor': 0, 'max_minor': 0})
        a.save(self.source / 'argo-release.json', manifest)
        self.d.validate(self.source)
        external = self.d.stage(self.source, 'external-camera')
        self.d.select(external)
        self.d.select(self.first)
        self.assertEqual(self.d.current.resolve(), self.first)
        self.assertFalse(any('surround-camerad' in str(op) for op in self.d.operations))
        (self.source / 'bin/argo-camerad').write_text('conflicting legacy owner')
        with self.assertRaisesRegex(ValueError, 'External Camera'):
            self.d.validate(self.source)
        (self.source / 'bin/argo-camerad').unlink()
        manifest['camera_api']['major'] = 2
        a.save(self.source / 'argo-release.json', manifest)
        with self.assertRaisesRegex(ValueError, 'API range'):
            self.d.validate(self.source)

    def test_ipc7_and_ipc8_require_view_contract_and_retain_older_rollback(self):
        retained = {}
        for version in (7, 8):
            with self.subTest(ipc=version):
                manifest = a.read(self.source / 'argo-release.json')
                manifest['ipc'] = version
                manifest.pop('native_view_contract', None)
                a.save(self.source / 'argo-release.json', manifest)
                with self.assertRaisesRegex(ValueError, 'ARVW'):
                    self.d.validate(self.source)
                manifest['native_view_contract'] = 2
                a.save(self.source / 'argo-release.json', manifest)
                with self.assertRaisesRegex(ValueError, 'ARVW'):
                    self.d.validate(self.source)
                manifest['native_view_contract'] = 1
                a.save(self.source / 'argo-release.json', manifest)
                retained[version] = self.d.stage(self.source, 'ipc-' + str(version))
                self.d.select(retained[version])
        self.d.select(retained[7])
        self.d.select(self.first)
        self.assertEqual(self.d.current.resolve(), self.first)
        self.assertFalse(any(op[0] == 'start' for op in self.d.operations))

    def test_unknown_or_non_integer_ipc_release_is_rejected(self):
        manifest = a.read(self.source / 'argo-release.json')
        manifest['native_view_contract'] = 1
        for version in (None, 5, 9, '8', 8.0, True):
            with self.subTest(ipc=version):
                manifest['ipc'] = version
                a.save(self.source / 'argo-release.json', manifest)
                with self.assertRaisesRegex(ValueError, 'IPC6/IPC7/IPC8'):
                    self.d.validate(self.source)

    def test_guard_boot_recovery_in_managed_daemon_startup(self):
        current = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        old = '00000000-0000-0000-0000-000000000001'
        marker = self.d.state / 'firewall-owned.json'
        a.save(self.d.config / 'daemon.json', {})
        self.d.running.add('graphical-session.target')
        original_lstat = Path.lstat
        def metadata(path, *args, **kwargs):
            if str(path) == '/usr/local/libexec/argo-projection-firewall':
                return types.SimpleNamespace(st_mode=0o100755, st_uid=0)
            return original_lstat(path, *args, **kwargs)
        cases = [
            ({'interface': 'wlan-test', 'boot_id': current}, False, False),
            ({'interface': 'wlan-test', 'boot_id': old}, True, False),
            ({'interface': 'wlan-test', 'boot_id': old}, True, True),
            ({'interface': 'wlan-test'}, False, False),
            ({'interface': 'wlan-test', 'boot_id': 'not-a-boot'}, False, False),
            ({'interface': '../oops', 'boot_id': old}, False, False),
            ({'interface': 'wlan-test', 'boot_id': None}, False, False),
            ('not-json', False, False),
        ]
        with patch.dict(a.os.environ, {'WAYLAND_DISPLAY': 'test',
                'DBUS_SESSION_BUS_ADDRESS': 'unix:path=test', 'INVOCATION_ID': 'test',
                'XDG_RUNTIME_DIR': str(self.d.home)}), patch.object(Path, 'lstat', metadata):
            for record, cleanup, failed in cases:
                with self.subTest(record=record, failed=failed):
                    a.save(marker, record)
                    if record == 'not-json': marker.write_text('{')
                    before = marker.read_bytes()
                    def helper(*args, **kwargs):
                        self.assertEqual(marker.read_bytes(), before)
                        if failed: raise subprocess.CalledProcessError(1, 'pkexec')
                        return subprocess.CompletedProcess(args, 0)
                    with patch.object(a.subprocess, 'run', side_effect=helper) as command, patch.object(a.os, 'execve') as execute:
                        if cleanup and not failed:
                            self.d.launch('daemon')
                            execute.assert_called_once()
                            self.assertFalse(marker.exists())
                        else:
                            with self.assertRaises(RuntimeError): self.d.launch('daemon')
                            execute.assert_not_called()
                            self.assertEqual(marker.read_bytes(), before)
                        if cleanup:
                            command.assert_called_once_with(['/usr/bin/pkexec', '/usr/local/libexec/argo-projection-firewall', 'stop', 'wlan-test'], check=True, timeout=45)
                        else: command.assert_not_called()

    def test_stopped_select_and_active_rollback(self):
        self.d.select(self.second)
        self.assertFalse(any(op[0] == 'start' for op in self.d.operations))
        self.d.running = {'argo.target', *a.UNITS}
        self.d.fail_start = True
        with self.assertRaisesRegex(RuntimeError, 'previous selection restored'):
            self.d.select(self.first)
        self.assertEqual(self.d.current.resolve(), self.second)
        self.assertEqual(self.d.running, {'argo.target', *a.UNITS})
        self.assertNotIn(('enable', 'argo.target'), self.d.operations)
        self.d.running = {'argo.target', 'argo-projectiond.service'}
        self.d.select(self.first)
        self.assertEqual(self.d.running, {'argo-projectiond.service'})

    def test_uncertain_cleanup_blocks_switch_and_replacement(self):
        self.d.running = {'argo.target', *a.UNITS}
        self.d.uncertain = True
        with self.assertRaisesRegex(RuntimeError, 'failed cleanup'):
            self.d.select(self.second)
        self.assertEqual(self.d.current.resolve(), self.first)
        self.assertFalse(any(op[0] == 'start' for op in self.d.operations))
        with patch.object(a, 'program_pids', return_value={123}):
            with self.assertRaisesRegex(RuntimeError, 'Stop foreground'):
                self.d.select(self.second)
        with self.assertRaisesRegex(ValueError, 'already exists'):
            self.d.stage(self.source, 'first')

    def test_integrity_ipc_ihs_and_daemon_only_update(self):
        replacement = self.d.home / 'daemon'; replacement.write_text('replacement'); replacement.chmod(0o755)
        a.save(Path(str(replacement) + '.json'), {'ipc': 5, 'sha256': a.digest(replacement)})
        with self.assertRaisesRegex(ValueError, 'IPC mismatch'):
            self.d.stage(self.first, 'bad', replacement)
        a.save(Path(str(replacement) + '.json'), {'ipc': 6, 'sha256': a.digest(replacement)})
        updated = self.d.stage(self.first, 'updated', replacement)
        self.assertEqual(a.digest(updated / 'lib/libapp.so'), a.digest(self.first / 'lib/libapp.so'))
        (updated / 'lib/libapp.so').write_text('corrupt')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            self.d.validate(updated)
        (self.d.home / 'ihs/bin/homescreen').write_text('other IHS')
        with self.assertRaisesRegex(ValueError, 'IHS differs'):
            self.d.validate(self.first)

    def test_release_specific_ihs_validates_launches_and_rolls_back_without_changing_global_prefix(self):
        original_configuration = (self.d.config / 'deployment.json').read_bytes()
        old_prefix = Path(self.d.settings()['ihs_prefix'])
        new_prefix = self.d.home / 'ihs-display-corrected'
        for relative in a.IHS_FILES:
            file = new_prefix / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes((old_prefix / relative).read_bytes())
        (new_prefix / 'bin/homescreen').write_text('corrected display identifiers')
        manifest = a.read(self.source / 'argo-release.json')
        manifest['ihs_prefix'] = str(new_prefix)
        manifest['ihs_sha256'] = {relative: a.digest(new_prefix / relative) for relative in a.IHS_FILES}
        a.save(self.source / 'argo-release.json', manifest)
        corrected = self.d.stage(self.source, 'display-corrected')
        self.d.validate(self.first)
        for release, expected_prefix in ((corrected, new_prefix), (self.first, old_prefix)):
            self.d.select(release)
            with patch.dict(a.os.environ, {'WAYLAND_DISPLAY': 'wayland-test',
                    'DBUS_SESSION_BUS_ADDRESS': 'unix:path=test', 'XDG_RUNTIME_DIR': str(self.d.home),
                    'LD_LIBRARY_PATH': '/ambient-must-not-win', 'ARGO_IHS_PREFIX': '/ambient-must-not-win'}), \
                    patch.object(a.os, 'execve') as execute:
                self.d.launch('app', managed=False)
                binary, command, environment = execute.call_args.args
                self.assertEqual(binary, str(expected_prefix / 'bin/homescreen'))
                self.assertEqual(command[0], binary)
                self.assertEqual(environment['LD_LIBRARY_PATH'], str(expected_prefix / 'lib') + ':' + str(release / 'lib'))
        self.assertEqual((self.d.config / 'deployment.json').read_bytes(), original_configuration)
        (new_prefix / 'bin/homescreen').write_text('unexpected change')
        with self.assertRaisesRegex(ValueError, 'IHS differs'):
            self.d.validate(corrected)
        self.d.validate(self.first)

    def test_release_specific_ihs_requires_absolute_existing_complete_prefix_and_matching_hashes(self):
        manifest = a.read(self.source / 'argo-release.json')
        for prefix in (None, True, 'relative/ihs', str(self.d.home / 'missing')):
            with self.subTest(prefix=prefix):
                a.save(self.source / 'argo-release.json', dict(manifest, ihs_prefix=prefix))
                with self.assertRaisesRegex(ValueError, 'IHS prefix'):
                    self.d.validate(self.source)
        incomplete = self.d.home / 'incomplete-ihs'
        incomplete.mkdir()
        a.save(self.source / 'argo-release.json', dict(manifest, ihs_prefix=str(incomplete)))
        with self.assertRaisesRegex(ValueError, 'Missing IHS file'):
            self.d.validate(self.source)
        a.save(self.source / 'argo-release.json', dict(manifest,
            ihs_prefix=self.d.settings()['ihs_prefix'], ihs_sha256={}))
        with self.assertRaisesRegex(ValueError, 'IHS differs'):
            self.d.validate(self.source)
        a.save(self.source / 'argo-release.json', dict(manifest,
            ihs_prefix=self.d.settings()['ihs_prefix'], package_runtime=1))
        with self.assertRaisesRegex(ValueError, 'Packaged runtime uses bundled IHS'):
            self.d.validate(self.source)

    def test_bundle_recorder_pins_the_known_matched_prefix_with_its_hashes(self):
        prefix = Path(self.d.settings()['ihs_prefix'])
        record = Path(__file__).with_name('record-build.py')
        subprocess.run([sys.executable, str(record), 'bundle', str(self.source),
                        '--ihs-prefix', str(prefix)], check=True, capture_output=True, text=True)
        manifest = a.read(self.source / 'argo-release.json')
        self.assertEqual(manifest['ihs_prefix'], str(prefix.resolve()))
        self.assertEqual(manifest['ihs_sha256'], {relative: a.digest(prefix / relative) for relative in a.IHS_FILES})
        self.d.validate(self.source)

    def test_app_environment_excludes_identity_and_ambient_options(self):
        a.save(self.d.config / 'daemon.json', {'ARGO_ANDROID_AUTO_KEY_FILE': '/private/key'})
        with patch.dict(a.os.environ, {'WAYLAND_DISPLAY': 'test-wayland',
                        'DBUS_SESSION_BUS_ADDRESS': 'unix:path=test',
                        'XDG_RUNTIME_DIR': str(self.d.home),
                        'ARGO_ANDROID_AUTO_KEY_FILE': '/ambient/key',
                        'ARGO_ANDROID_AUTO_CERT_FILE': '/ambient/cert',
                        'LD_PRELOAD': '/untrusted', 'INVOCATION_ID': 'test'}):
            with patch.object(a.os, 'execve') as execute:
                self.d.launch('app', managed=False)
                env = execute.call_args.args[2]
                self.assertNotIn('ARGO_ANDROID_AUTO_KEY_FILE', env)
                self.assertNotIn('ARGO_ANDROID_AUTO_CERT_FILE', env)
                self.assertNotIn('LD_PRELOAD', env)
                self.assertEqual(env['WAYLAND_DISPLAY'], 'test-wayland')
                self.assertEqual(env['ARGO_STARTUP_CONNECTIONS'], '')
                self.assertIn('--fullscreen', execute.call_args.args[1])
                self.assertFalse(any(arg.startswith(('--width', '--height', '--pixel-ratio'))
                                     for arg in execute.call_args.args[1]))

    def test_receivers_start_before_compositor_environment_import(self):
        a.save(self.d.config / 'daemon.json', {})
        bundle = self.carplay_bundle()
        self.d.select(bundle)
        self.d.running.add('graphical-session.target')
        with patch.dict(a.os.environ, {'XDG_RUNTIME_DIR': str(self.d.home),
                'INVOCATION_ID': 'early-login'}, clear=True), patch.object(a.os, 'execve') as execute:
            for role in ('daemon', 'carplay'):
                self.d.launch(role)
                self.assertEqual(execute.call_args.args[2].get('WAYLAND_DISPLAY'), None)
                self.assertEqual(a.read(self.d.marker(role))['result'], 'running')

    def test_graphical_boot_admits_each_current_role_while_the_session_target_is_activating(self):
        a.save(self.d.config / 'daemon.json', {})
        self.d.select(self.carplay_bundle())
        units = {'app': 'argo-app.service', 'daemon': 'argo-projectiond.service', 'carplay': a.CARPLAY_UNIT}
        for role, unit in units.items():
            def boot_status(name, timeout=125):
                if name == 'graphical-session.target':
                    return {'ActiveState': 'activating'}
                self.assertEqual(name, unit)
                return {'ActiveState': 'activating', 'MainPID': str(a.os.getpid()),
                        'InvocationID': 'boot-' + role}
            with self.subTest(role=role), patch.dict(a.os.environ, {
                    'XDG_RUNTIME_DIR': str(self.d.home), 'WAYLAND_DISPLAY': 'wayland-boot',
                    'DBUS_SESSION_BUS_ADDRESS': 'unix:path=boot', 'INVOCATION_ID': 'boot-' + role}, clear=True), \
                    patch.object(self.d, 'status', side_effect=boot_status), patch.object(a.os, 'execve') as execute:
                self.d.launch(role)
                execute.assert_called_once()
                self.assertEqual(a.read(self.d.marker(role))['invocation'], 'boot-' + role)

    def test_activating_graphical_target_rejects_manual_or_obsolete_launcher_ownership(self):
        cases = [
            {'ActiveState': 'activating', 'MainPID': str(a.os.getpid() + 1), 'InvocationID': 'boot'},
            {'ActiveState': 'activating', 'MainPID': str(a.os.getpid()), 'InvocationID': 'other'},
            {'ActiveState': 'activating', 'MainPID': str(a.os.getpid())},
            {'ActiveState': 'inactive', 'MainPID': str(a.os.getpid()), 'InvocationID': 'boot'},
        ]
        for service in cases:
            with self.subTest(service=service), patch.dict(a.os.environ, {'INVOCATION_ID': 'boot'}, clear=True), \
                    patch.object(self.d, 'status', side_effect=[{'ActiveState': 'activating'}, service]), \
                    patch.object(a.os, 'execve') as execute:
                with self.assertRaisesRegex(ValueError, 'No active graphical session'):
                    self.d.launch('app')
                execute.assert_not_called()
                self.assertFalse(self.d.marker('app').exists())

    def test_nongraphical_session_is_rejected_without_waiting_even_with_a_managed_invocation(self):
        for graphical in ('inactive', 'deactivating', 'failed', None):
            with self.subTest(graphical=graphical), patch.dict(a.os.environ, {'INVOCATION_ID': 'boot'}, clear=True), \
                    patch.object(self.d, 'status', return_value={'ActiveState': graphical}) as status, \
                    patch.object(a.os, 'execve') as execute, patch.object(a.time, 'sleep') as sleep:
                with self.assertRaisesRegex(ValueError, 'No active graphical session'):
                    self.d.launch('app')
                status.assert_called_once_with('graphical-session.target', timeout=1)
                execute.assert_not_called()
                sleep.assert_not_called()

    def test_managed_app_refreshes_session_environment_after_plasma_import(self):
        self.d.running.add('graphical-session.target')
        imported = subprocess.CompletedProcess([], 0,
            'WAYLAND_DISPLAY=wayland-late\nDBUS_SESSION_BUS_ADDRESS=unix:path=late\n'
            'ARGO_ANDROID_AUTO_KEY_FILE=/must-not-import\n', '')
        with patch.dict(a.os.environ, {'XDG_RUNTIME_DIR': str(self.d.home),
                'INVOCATION_ID': 'late-login'}, clear=True), \
                patch.object(self.d, 'systemctl', return_value=imported) as manager, \
                patch.object(a.os, 'execve') as execute:
            self.d.launch('app')
            env = execute.call_args.args[2]
            self.assertEqual(env['WAYLAND_DISPLAY'], 'wayland-late')
            self.assertEqual(env['DBUS_SESSION_BUS_ADDRESS'], 'unix:path=late')
            self.assertNotIn('ARGO_ANDROID_AUTO_KEY_FILE', env)
            manager.assert_called_once_with('show-environment', check=False)

    def test_failed_session_import_does_not_claim_runtime_ownership(self):
        self.d.running.add('graphical-session.target')
        with patch.dict(a.os.environ, {'XDG_RUNTIME_DIR': str(self.d.home),
                'INVOCATION_ID': 'missing-session'}, clear=True), \
                patch.object(a.time, 'monotonic', side_effect=[0, 21]), \
                patch.object(a.os, 'execve') as execute:
            with self.assertRaisesRegex(ValueError, 'KDE Wayland'):
                self.d.launch('app')
        execute.assert_not_called()
        self.assertFalse(self.d.marker('app').exists())

    def test_unclean_same_boot_invocation_blocks_replacement_and_preserves_evidence(self):
        boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        self.d.running.add('graphical-session.target')
        a.save(self.d.config / 'daemon.json', {})
        for result in ('running', 'unconfirmed'):
            record = dict(result=result, boot_id=boot, invocation='crashed')
            a.save(self.d.marker('daemon'), record)
            with patch.dict(a.os.environ, {'XDG_RUNTIME_DIR': str(self.d.home),
                    'INVOCATION_ID': 'replacement'}, clear=True), patch.object(a.os, 'execve') as execute:
                with self.assertRaisesRegex(RuntimeError, 'prior cleanup'):
                    self.d.launch('daemon')
                self.d.stopped('daemon')
            execute.assert_not_called()
            self.assertEqual(a.read(self.d.marker('daemon')), record)
        record['boot_id'] = 'previous-boot'
        a.save(self.d.marker('daemon'), record)
        with patch.dict(a.os.environ, {'XDG_RUNTIME_DIR': str(self.d.home),
                'INVOCATION_ID': 'new-boot'}, clear=True), patch.object(a.os, 'execve') as execute:
            self.d.launch('daemon')
        execute.assert_called_once()

    def test_exec_failure_is_clean_because_no_receiver_was_started(self):
        a.save(self.d.config / 'daemon.json', {})
        self.d.running.add('graphical-session.target')
        with patch.dict(a.os.environ, {'XDG_RUNTIME_DIR': str(self.d.home),
                'INVOCATION_ID': 'exec-failed'}, clear=True), \
                patch.object(a.os, 'execve', side_effect=FileNotFoundError):
            with self.assertRaises(FileNotFoundError):
                self.d.launch('daemon')
            self.d.stopped('daemon')
        self.assertEqual(a.read(self.d.marker('daemon'))['result'], 'clean')

    def test_daemon_readiness_uses_selected_ipc_and_accepts_fragmented_reply(self):
        for version in (6, 7, 8):
            with self.subTest(ipc=version):
                manifest = a.read(self.first / 'argo-release.json')
                manifest.update(ipc=version, native_view_contract=1)
                a.save(self.first / 'argo-release.json', manifest)
                peer = MagicMock()
                peer.__enter__.return_value = peer
                response = struct.pack('>IHHI', 0x4152474f, version, 6, 2) + b'ok'
                peer.recv.side_effect = [bytes([value]) for value in response]
                with patch.object(a.socket, 'socket', return_value=peer), \
                        patch.object(self.d, 'runtime', return_value=self.d.home):
                    self.d.ready('daemon')
                peer.sendall.assert_called_once_with(struct.pack('>IHHI', 0x4152474f, version, 65535, 0))

    def test_daemon_readiness_deadline_bounds_a_dripping_response(self):
        peer = MagicMock()
        peer.__enter__.return_value = peer
        peer.recv.return_value = b' '
        with patch.object(a.socket, 'socket', return_value=peer), \
                patch.object(self.d, 'runtime', return_value=self.d.home), \
                patch.object(a.time, 'sleep'), \
                patch.object(a.time, 'monotonic', side_effect=[0, 0, 1, 21, 21]):
            with self.assertRaisesRegex(RuntimeError, 'readiness probe'):
                self.d.ready('daemon')
        self.assertEqual(peer.recv.call_count, 1)

    def test_readiness_fails_immediately_after_current_main_process_exits(self):
        stopped = {'InvocationID': 'startup', 'MainPID': '0', 'ExecMainStatus': '78'}
        for role in ('app', 'daemon', 'carplay'):
            with self.subTest(role=role), patch.dict(a.os.environ, {'INVOCATION_ID': 'startup'}), \
                    patch.object(self.d, 'status', return_value=stopped) as status, \
                    patch.object(self.d, 'app_request') as request, \
                    patch.object(a.socket, 'socket') as socket, patch.object(a.time, 'sleep') as sleep:
                with self.assertRaisesRegex(RuntimeError, 'main process exited before readiness.*78'):
                    self.d.ready(role)
                status.assert_called_once()
                self.assertLessEqual(status.call_args.kwargs['timeout'], 1)
                request.assert_not_called()
                socket.assert_not_called()
                sleep.assert_not_called()

    def test_ready_response_is_rejected_if_the_main_process_has_just_exited(self):
        running = {'InvocationID': 'startup', 'MainPID': '123'}
        stopped = dict(running, MainPID='0', ExecMainStatus='1')
        response = {'ready': True, 'invocation': 'startup'}
        with patch.dict(a.os.environ, {'INVOCATION_ID': 'startup'}), \
                patch.object(self.d, 'status', side_effect=[running, stopped]), \
                patch.object(self.d, 'app_request', return_value=response), patch.object(a.time, 'sleep') as sleep:
            with self.assertRaisesRegex(RuntimeError, 'main process exited before readiness'):
                self.d.ready('app')
        sleep.assert_not_called()

    def test_obsolete_readiness_probe_cannot_accept_a_replacement_invocation(self):
        replacement = {'InvocationID': 'replacement', 'MainPID': '123'}
        with patch.dict(a.os.environ, {'INVOCATION_ID': 'startup'}), \
                patch.object(self.d, 'status', return_value=replacement), \
                patch.object(self.d, 'app_request') as request, patch.object(a.time, 'sleep') as sleep:
            with self.assertRaisesRegex(RuntimeError, 'invocation changed'):
                self.d.ready('app')
        request.assert_not_called()
        sleep.assert_not_called()

    def test_temporary_manager_failure_is_not_mistaken_for_main_process_exit(self):
        running = {'InvocationID': 'startup', 'MainPID': '123'}
        with patch.dict(a.os.environ, {'INVOCATION_ID': 'startup'}), \
                patch.object(self.d, 'status', side_effect=[subprocess.TimeoutExpired('show', 1), running, running]), \
                patch.object(self.d, 'app_request', return_value={'ready': True, 'invocation': 'startup'}) as request, \
                patch.object(a.time, 'sleep') as sleep:
            self.d.ready('app')
        request.assert_called_once_with('status')
        sleep.assert_called_once_with(0.1)

    def test_managed_readiness_cannot_accept_a_response_with_unknown_service_owner(self):
        with patch.dict(a.os.environ, {'INVOCATION_ID': 'startup'}), \
                patch.object(self.d, 'status', return_value={'MainPID': '123'}), \
                patch.object(self.d, 'app_request', return_value={'ready': True, 'invocation': 'startup'}) as request, \
                patch.object(a.time, 'monotonic', side_effect=[0, 0, 0, 31]), \
                patch.object(a.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'readiness probe before the deadline'):
                self.d.ready('app')
        request.assert_not_called()

    def test_live_starting_process_waits_for_its_matching_rendered_response(self):
        running = {'InvocationID': 'startup', 'MainPID': '123', 'ActiveState': 'activating'}
        replies = [{'ready': True, 'invocation': 'old'},
                   {'ready': False, 'invocation': 'startup'},
                   {'ready': True, 'invocation': 'startup'}]
        with patch.dict(a.os.environ, {'INVOCATION_ID': 'startup'}), \
                patch.object(self.d, 'status', return_value=running), \
                patch.object(self.d, 'app_request', side_effect=replies) as request, \
                patch.object(a.time, 'sleep') as sleep:
            self.d.ready('app')
        self.assertEqual(request.call_count, 3)
        self.assertEqual(sleep.call_count, 2)

    def test_display_configuration_uses_surface_configuration_not_guessed_mode(self):
        configuration = self.d.settings()
        configuration['display'] = {'fullscreen': False, 'width': 960, 'height': 720, 'output_index': 0}
        a.save(self.d.config / 'deployment.json', configuration)
        self.assertEqual(self.d.display_arguments(self.d.settings()),
                         ['--width=960', '--height=720', '--output-index=0'])
        for display in ({'fullscreen': False}, {'fullscreen': 'false'}, {'width': 0}, {'pixel_ratio': 2}):
            configuration['display'] = display
            a.save(self.d.config / 'deployment.json', configuration)
            with self.assertRaises(ValueError):
                self.d.settings()


class StartupOrderingTest(unittest.TestCase):
    def test_graphical_login_transaction_orders_members_not_just_the_argo_target(self):
        directory = Path(__file__).with_name('units')
        specifications = {}
        for name in ('argo.target', *a.ALL_UNITS):
            parser = configparser.ConfigParser(interpolation=None)
            parser.read(directory / name)
            specifications[name] = parser['Unit']

        # A target's Wants queues its members immediately. Model the actual
        # Argo transaction with other desktop dependencies already ready; the
        # graphical target can still be waiting for Plasma and remain inactive.
        transaction = {'argo.target'}
        queued = ['argo.target']
        while queued:
            name = queued.pop()
            for dependency in (specifications[name].get('Wants', '') + ' ' +
                               specifications[name].get('Requires', '')).split():
                if dependency in specifications and dependency not in transaction:
                    transaction.add(dependency)
                    queued.append(dependency)
        self.assertTrue(set(a.ALL_UNITS) <= transaction)
        graphical = 'graphical-session.target'
        transaction.add(graphical)
        after = {name: set() for name in transaction}
        for name, section in specifications.items():
            after[name].update(set(section.get('After', '').split()) & transaction)
            for dependency in set(section.get('Before', '').split()) & transaction:
                after[dependency].add(name)
            # Target default dependencies order the target after wanted
            # services, not those services after the target's prerequisites.
            if name.endswith('.target') and section.get('DefaultDependencies', 'yes') != 'no':
                after[name].update(set((section.get('Wants', '') + ' ' +
                                       section.get('Requires', '')).split()) & transaction)

        completed = set()
        def runnable():
            return {name for name in transaction - completed if after[name] <= completed}

        # Before the session barrier completes, no role may enter its launcher.
        # This fails if ordering is added only to argo.target: both receivers
        # would be runnable while the graphical-session target is still pending.
        self.assertEqual(runnable(), {graphical})
        completed.add(graphical)
        self.assertEqual(runnable(), {'argo-projectiond.service', a.CARPLAY_UNIT})
        completed.update(runnable())
        self.assertEqual(runnable(), {'argo-app.service'})
        completed.update(runnable())
        self.assertEqual(runnable(), {'argo.target'})
        completed.update(runnable())
        self.assertEqual(completed, transaction)  # Also rejects ordering cycles.


if __name__ == '__main__':
    unittest.main()
