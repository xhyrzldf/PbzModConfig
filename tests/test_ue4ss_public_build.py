"""Verify that a standalone build contains source files and safe release settings."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('public_ue4ss_build', ROOT / 'build_ue4ss.py')
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class PublicUe4ssBuildTests(unittest.TestCase):
    def setUp(self):
        (ROOT / '.local').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.local')
        self.addCleanup(self.temp.cleanup)
        self.out = Path(self.temp.name) / 'build'

    def test_source_build_has_entry_version_and_no_development_bridge(self):
        manifest = BUILD.build(self.out)
        expected = json.loads((ROOT / 'ue4ss-release.json').read_text(encoding='utf-8'))
        self.assertEqual(manifest['version'], expected['version'])
        self.assertEqual(manifest['game_build'], '26367565')
        scripts = self.out / 'ue4ss/Mods/PbzModConfig/Scripts'
        self.assertIn('local Dev = nil', (scripts / 'main.lua').read_text(encoding='utf-8'))
        self.assertFalse((scripts / 'PbzDevBridge.lua').exists())
        self.assertFalse(any(p.read_bytes().startswith(b'\x1bLua') for p in scripts.glob('*.lua')))
        self.assertEqual(len(manifest['files']), len(BUILD.LUA) + len(BUILD.SHARED) + 6)
        saved = json.loads((self.out / 'release-manifest.json').read_text(encoding='utf-8'))
        self.assertEqual(saved, manifest)

    def test_existing_output_is_never_overwritten(self):
        self.out.mkdir()
        sentinel = self.out / 'sentinel.txt'
        sentinel.write_text('unchanged', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'new directory'):
            BUILD.build(self.out)
        self.assertEqual(sentinel.read_text(encoding='utf-8'), 'unchanged')

    def test_output_outside_workspace_is_rejected(self):
        with tempfile.TemporaryDirectory() as elsewhere:
            with self.assertRaisesRegex(ValueError, 'under .local'):
                BUILD.build(Path(elsewhere) / 'release')


if __name__ == '__main__':
    unittest.main()
