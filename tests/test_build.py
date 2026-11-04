from unittest import mock
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


class LoaderBuildTests(unittest.TestCase):
    def setUp(self):
        root = BUILD.REPO / ".local/pbz-modconfig"
        root.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix="loader-build-test-", dir=root)
        self.addCleanup(temporary.cleanup)
        self.out = Path(temporary.name) / "output"

    def test_loader_stage_has_only_authored_files_and_true_hashes(self):
        manifest = BUILD.stage_pbzmodloader(self.out)
        self.assertEqual(manifest["runtime"], "pbzmodloader")
        self.assertEqual(manifest["requires"], {"runtime.PBZModLoader": "0.3.6-preview"})
        self.assertEqual(manifest["build"], "26367565")
        self.assertEqual(manifest["entry"], BUILD.LOADER_ROOT + "main.js")
        self.assertEqual(manifest["overrides"], [])
        expected = {BUILD.LOADER_ROOT + name for name in BUILD.FILES + BUILD.LOADER_FILES}
        expected.update("ProjectPBZ/Content/JavaScript/PbzModConfig/" + name for name in BUILD.ASSETS)
        actual = {row["path"] for row in manifest["files"]}
        self.assertEqual(actual, expected)
        self.assertEqual(set(manifest["added"]), expected)
        self.assertNotIn(BUILD.ORIGINAL, actual)
        self.assertNotIn("source", manifest)
        self.assertNotIn("artifacts", manifest)
        for row in manifest["files"]:
            data = (self.out / "stage" / row["path"]).read_bytes()
            self.assertEqual(row["bytes"], len(data))
            self.assertEqual(row["sha256"], BUILD.sha(data))
        for name in BUILD.LOADER_FILES:
            self.assertEqual((self.out / "stage" / BUILD.LOADER_ROOT / name).read_bytes(),
                             (HERE / "loader" / name).read_bytes())

    def test_loader_cli_does_not_read_an_original_or_invoke_the_pak_builder(self):
        result = subprocess.run([
            "python", str(HERE / "build.py"), "--runtime", "pbzmodloader",
            "--out", str(self.out), "--source-root", str(self.out / "missing-original")
        ], text=True, encoding="utf-8", capture_output=True, check=True)
        status = json.loads(result.stdout)
        self.assertEqual(status["status"], "staged")
        self.assertEqual(status["runtime"], "pbzmodloader")
        self.assertEqual({path.name for path in self.out.iterdir()}, {"stage", "manifest.json"})
        self.assertFalse(any(path.suffix in {".pak", ".utoc", ".ucas"} for path in self.out.rglob("*")))

    def test_existing_stage_is_rejected_without_merging_files(self):
        marker = self.out / "stage/untouched.txt"
        marker.parent.mkdir(parents=True)
        marker.write_text("keep", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "stage"):
            BUILD.stage_pbzmodloader(self.out)
        self.assertEqual(list(marker.parent.iterdir()), [marker])

    def test_missing_source_does_not_leave_a_partial_stage(self):
        with mock.patch.object(BUILD, "LOADER_FILES", ("missing-module.js",)):
            with self.assertRaises(FileNotFoundError):
                BUILD.stage_pbzmodloader(self.out)
        self.assertFalse((self.out / "stage").exists())


if __name__ == "__main__":
    unittest.main()
