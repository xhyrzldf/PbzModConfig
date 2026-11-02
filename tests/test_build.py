import importlib.util
import json
from pathlib import Path
import unittest
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("pbz_config_build", HERE / "build.py")
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class BuildTests(unittest.TestCase):
    def test_all_languages_load_without_other_mod_sources(self):
        script = "const d=require('./src/LocaleStrings');console.log(JSON.stringify({languages:Object.keys(d.catalogs),signature:d.signatures.vi,tab:d.catalogs.vi.tab}));"
        result = subprocess.run(['node', '-e', script], cwd=HERE, capture_output=True, text=True, encoding='utf-8', check=True)
        data = json.loads(result.stdout)
        self.assertEqual(set(data['languages']), {'zhHans','en','zhHant','ko','ru','es-ES','es-419','vi'})
        self.assertEqual(data['signature'], 'TRÒ CHƠI MỚI')
        self.assertTrue(data['tab'])

    def test_only_single_anchor_changes(self):
        original = ('"use strict";\n' + BUILD.ANCHOR + '\n// end').encode()
        result = BUILD.patch_source(original, BUILD.sha(original))
        self.assertEqual(result.replace(BUILD.PATCH, ""), original.decode())
        self.assertEqual(result.count("PbzModConfig/native/Entry"), 1)

    def test_changed_original_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "哈希"):
            BUILD.patch_source(b"wrong")

    def test_bad_anchors_are_rejected(self):
        for text in ("nothing", BUILD.ANCHOR * 2, BUILD.ANCHOR + "PbzModConfig/native/Entry"):
            data = text.encode()
            with self.assertRaises(ValueError):
                BUILD.patch_source(data, BUILD.sha(data))

    def test_no_other_mod_overrides_or_test_runtime(self):
        self.assertEqual(BUILD.ORIGINAL, "ProjectPBZ/Content/JavaScript/UI/Setting/SettingPanel.js")
        self.assertFalse(any(any(x in f for x in ("Map.js", "RenewalPlayer.js", "MainStart.js", "tests/", "tools/", "demo/")) for f in BUILD.FILES))

    def test_output_cannot_enter_game_or_root(self):
        game = BUILD.REPO / ".local/fake-game"
        for target in (game / "Paks", BUILD.REPO, BUILD.REPO / ".local"):
            with self.assertRaises(ValueError):
                BUILD.validate_output(target, game)
        BUILD.validate_output(BUILD.REPO / ".local/modconfig-build", game)

    def test_output_cannot_escape_repository(self):
        with self.assertRaises(ValueError):
            BUILD.validate_output(BUILD.REPO.parent / "unrelated-build", None)
        with self.assertRaises(ValueError):
            BUILD.validate_output(BUILD.REPO / ".local/../../unrelated-build", None)

    def test_existing_output_is_rejected_without_changing_files(self):
        root = BUILD.REPO / ".local"
        root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as directory:
            marker = Path(directory) / "keep.txt"
            marker.write_text("keep", encoding="utf-8")
            result = subprocess.run([sys.executable, str(HERE / "build.py"),
                                     "--source-root", directory, "--out", directory,
                                     "--stage-only"], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(encoding="utf-8"), "keep")
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), ["keep.txt"])


if __name__ == "__main__":
    unittest.main()
