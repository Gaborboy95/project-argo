import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader('doctor_argoctl', str(Path(__file__).with_name('argoctl')))
spec = importlib.util.spec_from_loader(loader.name, loader)
a = importlib.util.module_from_spec(spec)
loader.exec_module(a)

class DoctorTest(unittest.TestCase):
    def test_missing_release_reports_without_creating_state(self):
        with tempfile.TemporaryDirectory() as root:
            deployment = a.Deployment(Path(root))
            with patch.object(a.subprocess, 'run', side_effect=FileNotFoundError), patch.object(a, 'program_pids', return_value=set()):
                result = a.doctor(deployment, environment={})
            self.assertFalse(result['ok'])
            self.assertTrue(result['readOnly'])
            self.assertEqual(list(Path(root).iterdir()), [])
            states = {c['check']: c['state'] for c in result['checks']}
            self.assertEqual(states['release.selected'], 'failed')
            self.assertEqual(states['camera.provider'], 'ready')
            self.assertEqual(states['session.wayland'], 'offline')

    def test_invalid_camera_provider_does_not_fall_back(self):
        with tempfile.TemporaryDirectory() as root, patch.object(a.subprocess, 'run', side_effect=FileNotFoundError):
            result = a.doctor(a.Deployment(Path(root)), environment={'ARGO_CAMERA_BACKEND': 'typo'})
            self.assertEqual(next(c['state'] for c in result['checks'] if c['check'] == 'camera.provider'), 'failed')

    def test_probes_cannot_update_gstreamer_registry(self):
        with tempfile.TemporaryDirectory() as root, patch.object(a.subprocess, 'run') as run:
            run.return_value.returncode = 0
            a.doctor(a.Deployment(Path(root)), environment={})
            probes = [call for call in run.call_args_list if call.args[0][0] == 'gst-inspect-1.0']
            self.assertTrue(probes)
            for call in probes:
                self.assertEqual(call.kwargs['env']['GST_REGISTRY_UPDATE'], 'no')
                self.assertEqual(call.kwargs['env']['GST_REGISTRY'], '/dev/null')
