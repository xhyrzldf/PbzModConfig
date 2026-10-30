"""A package must not escape its staging directory or silently replace a file."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("container_builder", ROOT / "tools/build_js_mod.py")
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class ContainerTests(unittest.TestCase):
    def setUp(self):
        root = ROOT / ".local"
        root.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=root)
        self.addCleanup(self.temporary.cleanup)
        self.source = Path(self.temporary.name) / "fixture.js"
        self.source.write_text('"use strict";\n', encoding="utf-8")

    def test_regular_content_path(self):
        inner = "ProjectPBZ/Content/JavaScript/Example.js"
        self.assertEqual(BUILDER.parse_files([f"{inner}={self.source}"]), {inner: self.source})

    def test_escape_and_ambiguous_paths_are_rejected(self):
        for inner in ("../outside.js", "/ProjectPBZ/Content/a.js",
                      "ProjectPBZ/Content/../../outside.js", "ProjectPBZ/Content/a\\b.js",
                      "ProjectPBZ/Content/a:stream", "ProjectPBZ/Content//a.js"):
            with self.subTest(inner=inner), self.assertRaises(ValueError):
                BUILDER.parse_files([f"{inner}={self.source}"])

    def test_duplicates_and_missing_files_are_rejected(self):
        spec = f"ProjectPBZ/Content/fixture.js={self.source}"
        with self.assertRaises(ValueError):
            BUILDER.parse_files([spec, spec])
        with self.assertRaises(ValueError):
            BUILDER.parse_files([spec + ".missing"])


if __name__ == "__main__":
    unittest.main()
