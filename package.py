"""Package a checked player build using the installer's signed package protocol."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ARTIFACTS = {f"zzz_PBZModConfig_P.{ext}" for ext in ("pak", "utoc", "ucas")}
LOADER_TARGET = "ProjectPBZ/PBZModLoader/mods/pbz-mod-config/"
LOADER_ASSETS = {"ProjectPBZ/Content/JavaScript/PbzModConfig/assets/" + name
                 for name in ("modconfig-icon.png", "color-wheel.png")}
LOADER_DEPENDENCY = {"id": "runtime.PBZModLoader", "minVersion": "0.3.6-preview",
                     "reason": {"zh-Hans": "需要 PBZModLoader 0.3.6-preview 共享前置",
                                "en": "Requires the shared PBZModLoader 0.3.6-preview runtime."}}


def validate_loader_files(build, manifest):
    paths = [entry["path"] for entry in manifest["files"]]
    if len(paths) != len({path.lower() for path in paths}) or LOADER_TARGET + "main.js" not in paths:
        raise ValueError("加载器构建存在重复文件或缺少 main.js")
    if manifest.get("overrides") or manifest.get("requires") != {"runtime.PBZModLoader": "0.3.6-preview"}:
        raise ValueError("加载器构建的覆盖范围或前置声明不符")
    for entry in manifest["files"]:
        name = entry["path"]
        if ("\\" in name or any(part in ("", ".", "..") for part in name.split("/"))
                or not (name in LOADER_ASSETS or (name.startswith(LOADER_TARGET) and name.endswith(".js")))):
            raise ValueError("加载器构建包含非法目标：" + name)
        target = build / "stage" / name
        if not target.resolve().is_relative_to((build / "stage").resolve()):
            raise ValueError("加载器构建路径越界：" + name)
        data = target.read_bytes()
        if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise ValueError("加载器构建文件已改变：" + name)
    actual = {path.relative_to(build / "stage").as_posix()
              for path in (build / "stage").rglob("*") if path.is_file()}
    if actual != set(paths):
        raise ValueError("加载器目录存在清单外文件")


def release_spec_for_build(manifest, spec):
    if manifest.get("runtime") != "pbzmodloader":
        return spec
    result = copy.deepcopy(spec)
    result["containers"] = []
    result["gameBuilds"] = [manifest["build"]]
    result["overrides"] = []
    result["files"] = [{"source": "stage/" + row["path"], "target": row["path"]}
                       for row in manifest["files"]]
    dependencies = result.setdefault("dependencies", {})
    required = [entry for entry in dependencies.get("required", [])
                if entry.get("id") != LOADER_DEPENDENCY["id"]]
    dependencies["required"] = required + [dict(LOADER_DEPENDENCY)]
    return result


def validate_build(build):
    manifest = json.loads((build / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("runtimeBlocked"):
        raise ValueError("该构建已确认受游戏脚本完整性校验阻止，不能制作发行包")
    if manifest.get("demoIncluded") is not False or any("/demo/" in f["path"] for f in manifest["files"]):
        raise ValueError("玩家发行包不能包含配置演示")
    if manifest.get("runtime") == "pbzmodloader":
        validate_loader_files(build, manifest)
        return manifest
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
    spec_path = HERE / "release-spec.json"
    if manifest.get("runtime") == "pbzmodloader":
        spec = release_spec_for_build(manifest, json.loads(spec_path.read_text(encoding="utf-8")))
        spec_path = args.build / "release-spec-loader.json"
        spec_path.write_text(json.dumps(spec, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(args.packer.resolve()), "package", "--spec", str(spec_path.resolve()),
                    "--build", str(args.build.resolve()), "--version", manifest["version"],
                    "--channel", "preview" if "-" in manifest["version"] else "stable",
                    "--key", str(args.key.resolve()), "--readme", str(HERE / ("PLAYER-README-loader.txt" if manifest.get("runtime") == "pbzmodloader" else "PLAYER-README.txt")),
                    "--out", str(args.out.resolve())], check=True)


if __name__ == "__main__":
    main()
