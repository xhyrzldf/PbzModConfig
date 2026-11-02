"""Build the native settings preview; never installs or contacts a running game."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE
ORIGINAL = "ProjectPBZ/Content/JavaScript/UI/Setting/SettingPanel.js"
SOURCE_SHA256 = "51aeade8f90f7b3a2ba0e6c4192db9079fc3f9e0628753be07cffa8726eb2cea"
ANCHOR = "exports.SettingPanelMixinInterface = SettingPanelMixinInterface;"
PATCH = '\ntry { require("../../PbzModConfig/native/Entry").install(SettingPanelMixinInterface, UE, puerts_1, exports, {clearPendingSelect, cancelSelectWidgetFocusTimer}); } catch (error) { console.warn("[PbzModConfig] BOOT_FAILED " + String(error)); }\n'
FILES = (
    "provider/Protocol.js", "provider/Schema.js", "provider/Controls.js", "provider/Compatibility.js", "provider/ConfigStore.js", "provider/Translations.js",
    "provider/Journal.js", "provider/EasyCsvIO.js", "provider/StorageRoot.js", "src/Framework.js", "src/Editors.js", "src/Localization.js", "src/LocaleStrings.js", "src/Metadata.js",
    "native/NativeSupport.js", "native/NativeRows.js", "native/NativeMenu.js", "native/Entry.js", "native/NativeFooter.js", "native/NativeIcon.js", "native/NativePreview.js", "src/ColorPalette.js",
)
ASSETS = ("assets/modconfig-icon.png", "assets/color-wheel.png")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch_source(data: bytes, expected_hash: str = SOURCE_SHA256) -> str:
    if sha(data) != expected_hash:
        raise ValueError("原版 SettingPanel.js 哈希变化，先重新核对补丁边界")
    source = data.decode("utf-8")
    if source.count(ANCHOR) != 1 or "PbzModConfig/native/" in source:
        raise ValueError("补丁锚点缺失、重复或源码已被修改")
    return source.replace(ANCHOR, ANCHOR + PATCH)


def validate_output(out: Path, game_root: Path | None) -> None:
    resolved = out.resolve()
    if game_root and resolved.is_relative_to(game_root.resolve()):
        raise ValueError("构建入口禁止写入游戏目录")
    if not resolved.is_relative_to((REPO / ".local").resolve()):
        raise ValueError("输出仅允许仓库 .local 下的专用构建目录")
    if resolved == (REPO / ".local").resolve():
        raise ValueError("必须指定独立子目录")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True,
                        help="原版脚本导出根目录，包含 ProjectPBZ/Content/JavaScript")
    parser.add_argument("--game-root", type=Path, help="游戏安装目录，用于拒绝向游戏目录输出")
    parser.add_argument("--repak", type=Path, help="repak 可执行文件；完整构建必填")
    parser.add_argument("--retoc", type=Path, help="retoc 可执行文件；完整构建必填")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--stage-only", action="store_true")
    args = parser.parse_args()
    validate_output(args.out, args.game_root)
    if args.out.exists():
        raise ValueError("输出目录已存在；使用新目录，避免覆盖或混入旧产物")
    if not args.stage_only:
        for name, tool in (("repak", args.repak), ("retoc", args.retoc)):
            if tool is None or not tool.is_file():
                parser.error(f"完整构建需要 --{name} 指向可执行文件")
    source_root = args.source_root
    original = source_root / ORIGINAL
    patched = patch_source(original.read_bytes())
    stage = args.out.resolve() / "stage"
    if stage.exists():
        raise ValueError("目标 stage 已存在；使用新目录，避免混入旧产物")
    stage.mkdir(parents=True)
    output_source = stage / ORIGINAL
    output_source.parent.mkdir(parents=True)
    output_source.write_text(patched, encoding="utf-8", newline="\n")
    payloads = {ORIGINAL: output_source}
    for name in FILES + ASSETS:
        inner = "ProjectPBZ/Content/JavaScript/PbzModConfig/" + name
        target = stage / inner
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((HERE / name).read_bytes())
        payloads[inner] = target
    for target in payloads.values():
        if target.suffix == ".js":
            subprocess.run(["node", "--check", str(target)], check=True)
    version = subprocess.check_output(["node", "-p", "require(process.argv[1]).version", str(HERE / "src/Metadata.js")], text=True).strip()
    manifest = {
        "version": version, "build": "26266538", "kind": "native-menu-preview-not-release", "demoIncluded": False,
        "nativeMenuImplemented": True, "gameTested": False,
        "source": {"path": ORIGINAL, "sha256": sha(original.read_bytes())},
        "overrides": [ORIGINAL], "added": sorted(set(payloads) - {ORIGINAL}),
        "files": [{"path": name, "bytes": file.stat().st_size, "sha256": sha(file.read_bytes())} for name, file in payloads.items()],
    }
    if not args.stage_only:
        command = [sys.executable, "-I", str(REPO / "tools/build_js_mod.py"),
                   "--name", "zzz_PBZModConfig_P", "--out", str(args.out.resolve()),
                   "--repak", str(args.repak.resolve()), "--retoc", str(args.retoc.resolve())]
        for name, file in payloads.items():
            command.extend(["--file", f"{name}={file}"])
        subprocess.run(command, check=True)
        manifest["artifacts"] = []
        for suffix in ("pak", "utoc", "ucas"):
            file = args.out.resolve() / f"zzz_PBZModConfig_P.{suffix}"
            manifest["artifacts"].append({"file": file.name, "bytes": file.stat().st_size, "sha256": sha(file.read_bytes())})
    (args.out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "staged" if args.stage_only else "built", "manifest": str((args.out / "manifest.json").resolve()), "gameTested": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
