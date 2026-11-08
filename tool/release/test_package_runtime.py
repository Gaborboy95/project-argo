"""Pure package-input contract tests; no dpkg, native loading or installation."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    'package_runtime', Path(__file__).with_name('package-runtime.py'))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class ProjectionContractTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.source = root / 'application-source'
        self.native = root / 'native-build-source'
        self.bundle = root / 'flutter-bundle'
        self.bundle.mkdir()
        self.dart = self.source / 'lib/integrations/projection/projection_ipc.dart'
        self.rust = self.native / 'projection/argo-projectiond/src/ipc.rs'
        self.dart.parent.mkdir(parents=True)
        self.rust.parent.mkdir(parents=True)
        self.versions(8, 8)

    def versions(self, native, dart):
        self.rust.write_text(f'pub const VERSION: u16 = {native};\n')
        self.dart.write_text(f'class ProjectionIpcProtocol {{ static const int version = {dart}; }}\n')

    def matched(self, definition=None):
        return runtime.matched_projection_ipc(self.source, self.native, self.bundle, definition)

    def test_manifest_version_follows_the_matched_sources_without_a_constant(self):
        for version in (7, 8, 9):
            with self.subTest(version=version):
                self.versions(version, version)
                self.assertEqual(self.matched(), version)

    def test_a_different_native_source_root_cannot_disagree_with_the_application(self):
        self.versions(7, 8)
        with self.assertRaisesRegex(ValueError, 'source IPC versions disagree'):
            self.matched()

    def test_available_flutter_bundle_record_must_match_the_sources(self):
        manifest = self.bundle / 'argo-release.json'
        manifest.write_text(json.dumps({'ipc': 8}))
        self.assertEqual(self.matched(), 8)
        for recorded in (7, 9, None, '8', 8.0, True):
            with self.subTest(recorded=recorded):
                manifest.write_text(json.dumps({'ipc': recorded}))
                with self.assertRaisesRegex(ValueError, 'bundle manifest IPC'):
                    self.matched()

    def test_locked_release_definition_must_match_instead_of_being_silently_upgraded(self):
        self.assertEqual(self.matched({'contracts': {'aa_ipc': 8}}), 8)
        for recorded in (7, 9, None, '8', 8.0, True):
            with self.subTest(recorded=recorded):
                with self.assertRaisesRegex(ValueError, 'Release definition AA IPC'):
                    self.matched({'contracts': {'aa_ipc': recorded}})
        self.assertEqual(self.matched({}), 8)
        self.versions(7, 7)
        self.assertEqual(self.matched({'contracts': {'aa_ipc': 7}}), 7)

    def test_missing_or_malformed_contracts_fail_before_packaging(self):
        self.rust.write_text('pub const OTHER: u16 = 8;\n')
        with self.assertRaisesRegex(ValueError, 'Missing canonical'):
            self.matched()
        self.versions(8, 8)
        self.dart.write_text('class ProjectionIpcProtocol {}\n')
        with self.assertRaisesRegex(ValueError, 'Missing canonical'):
            self.matched()
        self.versions(8, 8)
        (self.bundle / 'argo-release.json').write_text('{')
        with self.assertRaises(ValueError):
            self.matched()


if __name__ == '__main__':
    unittest.main()
