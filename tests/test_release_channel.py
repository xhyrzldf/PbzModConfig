"""Prevent stable releases from silently retaining the signed preview channel."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("pbz_config_channel_package", HERE / "package.py")
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class ReleaseChannelTests(unittest.TestCase):
    def test_signed_channel_matches_stable_and_preview_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory)
            manifest = {
                "demoIncluded": False,
                "files": [{"path": "ProjectPBZ/Content/JavaScript/PbzModConfig/native/Entry.js"}],
                "overrides": ["ProjectPBZ/Content/JavaScript/UI/Setting/SettingPanel.js"],
                "artifacts": [],
            }
            for name in sorted(PACKAGE.ARTIFACTS):
                data = name.encode()
                (build / name).write_bytes(data)
                manifest["artifacts"].append({"file": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
            for version, channel in (("0.3.5", "stable"), ("0.2.5-preview", "preview")):
                with self.subTest(version=version):
                    manifest["version"] = version
                    (build / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
                    argv = ["package.py", "--build", str(build), "--packer", str(build / "packer.exe"),
                            "--key", str(build / "test.key"), "--out", str(build / (version + ".zip"))]
                    with patch("sys.argv", argv), patch.object(PACKAGE.subprocess, "run") as run:
                        PACKAGE.main()
                    command = run.call_args.args[0]
                    self.assertEqual(command[command.index("--channel") + 1], channel,
                                     "The signed channel, not just the displayed version, controls updates")
                    self.assertEqual(command[command.index("--version") + 1], version)


if __name__ == "__main__":
    unittest.main()
