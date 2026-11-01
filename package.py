"""Package a checked player build using the installer's signed package protocol."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ARTIFACTS = {f"zzz_PBZModConfig_P.{ext}" for ext in ("pak", "utoc", "ucas")}


def validate_build(build):
    manifest = json.loads((build / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("demoIncluded") is not False or any("/demo/" in f["path"] for f in manifest["files"]):
        raise ValueError("玩家发行包不能包含配置演示")
    if manifest["overrides"] != ["ProjectPBZ/Content/JavaScript/UI/Setting/SettingPanel.js"]:
        raise ValueError("原版覆盖清单不符合本框架边界")
    artifacts = manifest.get("artifacts", [])
    if len(artifacts) != 3 or {f["file"] for f in artifacts} != ARTIFACTS:
        raise ValueError("构建三件套缺失或包含意外文件")
    for artifact in artifacts:
        data = (build / artifact["file"]).read_bytes()
        if len(data) != artifact["bytes"] or hashlib.sha256(data).hexdigest() != artifact["sha256"]:
            raise ValueError("构建文件已改变：" + artifact["file"])
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--packer", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True, help="发布者私钥路径；不读取或打印其内容")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.out.exists():
        raise ValueError("发行包已存在，请使用新路径")
    manifest = validate_build(args.build)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(args.packer.resolve()), "package", "--spec", str(HERE / "release-spec.json"),
                    "--build", str(args.build.resolve()), "--version", manifest["version"],
                    "--channel", "preview" if "-" in manifest["version"] else "stable",
                    "--key", str(args.key.resolve()), "--readme", str(HERE / "PLAYER-README.txt"),
                    "--out", str(args.out.resolve())], check=True)


if __name__ == "__main__":
    main()
