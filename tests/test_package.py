"""Reject packages that could ship test UI, stale bytes or unrelated overrides."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("pbz_config_package", HERE / "package.py")
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class PackageTests(unittest.TestCase):
    def setUp(self):
        root = HERE / ".local/package-tests"
        root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="package-fixture-", dir=root)
        self.addCleanup(self.temp.cleanup)
        self.build = Path(self.temp.name)
        self.manifest = {
            "version": "0.2.5-preview", "demoIncluded": False,
            "files": [{"path": "ProjectPBZ/Content/JavaScript/PbzModConfig/native/Entry.js"}],
            "overrides": ["ProjectPBZ/Content/JavaScript/UI/Setting/SettingPanel.js"],
            "artifacts": [],
        }
        for name in sorted(PACKAGE.ARTIFACTS):
            data = name.encode()
            (self.build / name).write_bytes(data)
            self.manifest["artifacts"].append({"file": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})

    def validate(self):
        (self.build / "manifest.json").write_text(json.dumps(self.manifest), encoding="utf-8")
        return PACKAGE.validate_build(self.build)

    def test_valid_player_build(self):
        self.assertEqual(self.validate()["version"], "0.2.5-preview")

    def test_demo_flag_is_rejected(self):
        self.manifest["demoIncluded"] = True
        with self.assertRaisesRegex(ValueError, "演示"):
            self.validate()

    def test_demo_file_is_rejected_even_with_false_flag(self):
        self.manifest["files"].append({"path": "ProjectPBZ/Content/JavaScript/PbzModConfig/demo/DemoProvider.js"})
        with self.assertRaisesRegex(ValueError, "演示"):
            self.validate()

    def test_incomplete_container_is_rejected(self):
        self.manifest["artifacts"].pop()
        with self.assertRaisesRegex(ValueError, "三件套"):
            self.validate()

    def test_changed_payload_is_rejected(self):
        item = self.manifest["artifacts"][0]
        data = (self.build / item["file"]).read_bytes()
        (self.build / item["file"]).write_bytes(b"x" * len(data))
        with self.assertRaisesRegex(ValueError, "已改变"):
            self.validate()

    def test_other_game_override_is_rejected(self):
        self.manifest["overrides"].append("ProjectPBZ/Content/JavaScript/UI/Widget/Map.js")
        with self.assertRaisesRegex(ValueError, "覆盖清单"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
