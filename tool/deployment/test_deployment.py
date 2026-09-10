"""No radio mutations: exercise actual release transactions with an injected manager."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

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

    def status(self, unit):
        return {'ActiveState': 'active' if unit in self.running else 'inactive',
                'Result': 'failure' if self.uncertain and unit in a.UNITS else 'success'}

    def systemctl(self, *args, check=True):
        self.operations.append(args)
        if args[0] == 'stop':
            self.running.clear()
        if args[0] == 'start':
            if self.fail_start:
                self.fail_start = False
                raise subprocess.CalledProcessError(1, 'start')
            self.running.update(args[1:])
            if 'argo.target' in args:
                self.running.update(a.UNITS)
        return subprocess.CompletedProcess(args, 0, '', '')


class DeploymentTest(unittest.TestCase):
    def setUp(self):
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


if __name__ == '__main__':
    unittest.main()
