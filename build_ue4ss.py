"""Build the open-source UE4SS edition without touching the game directory."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
MOD = "PbzModConfig"
SHARED = ("PbzBindingRules.lua", "PbzNativeRows.lua", "PbzNativeWidgets.lua")
LUA = (
    "PbzChoiceFont.lua", "PbzColorPalette.lua", "PbzConfigBridge.lua", "PbzConfigCore.lua",
    "PbzDiagnostics.lua", "PbzEditors.lua", "PbzLegacyProjection.lua", "PbzLocale.lua",
    "PbzLocaleMonitor.lua", "PbzModConfigClient.lua", "PbzModConfigMetadata.lua", "PbzModConfigRuntime.lua",
    "PbzNativeActionBar.lua", "PbzNativeApi.lua", "PbzNativeConfirm.lua", "PbzNativeEvents.lua",
    "PbzNativeFooter.lua", "PbzNativeKeys.lua", "PbzNativeMenu.lua", "PbzNativePreviewPane.lua",
    "PbzNativeSelection.lua", "PbzNativeTabs.lua", "PbzNavigation.lua", "PbzNumberFormat.lua",
    "PbzPreviewAudio.lua", "PbzProviderHub.lua", "PbzRemoteHost.lua", "PbzSharedHost.lua",
    "PbzStoreProvider.lua", "PbzVisualPreview.lua",
)


def _lua_value(value):
    if value is True:
        return "true"
    if isinstance(value, str):
        equals = ""
        while "]" + equals + "]" in value:
            equals += "="
        return "[" + equals + "[" + value + "]" + equals + "]"
    raise ValueError("Invalid capability value")


def build(output: Path):
    out = output.resolve()
    local = (ROOT / ".local").resolve()
    if not out.is_relative_to(local) or out == local or out.exists():
        raise ValueError("Output must be a new directory under .local")
    spec = json.loads((ROOT / "ue4ss-release.json").read_text(encoding="utf-8"))
    caps = spec["capabilities"]
    meta = (ROOT / "ue4ss/PbzModConfigMetadata.lua").read_text(encoding="utf-8")
    if f'version = "{spec["version"]}"' not in meta:
        raise ValueError("Lua version does not match the release specification")
    dest = out / "ue4ss/Mods" / MOD
    scripts = dest / "Scripts"
    scripts.mkdir(parents=True)
    try:
        for name in LUA:
            shutil.copyfile(ROOT / "ue4ss" / name, scripts / name)
        for name in SHARED:
            shutil.copyfile(ROOT / "lua" / name, scripts / name)
        for name in ("modconfig-icon.png", "color-wheel.png"):
            shutil.copyfile(ROOT / "assets" / name, scripts / name)
        shutil.copyfile(ROOT / "vendor/dkjson.lua", scripts / "dkjson.lua")
        translated = subprocess.run(["node", str(ROOT / "ue4ss/build_framework_strings.cjs")],
                                    check=True, capture_output=True).stdout
        if not translated.strip():
            raise ValueError("Localization generation failed")
        (scripts / "PbzFrameworkStrings.lua").write_bytes(translated)
        main = (ROOT / "ue4ss/main.lua").read_text(encoding="utf-8")
        marker = "local Capabilities = {} -- PBZ_CAPABILITIES"
        if main.count(marker) != 1 or main.count("local Dev = nil -- PBZ_DEV_CONFIG") != 1:
            raise ValueError("Unexpected release entry point")
        text = "{" + ",".join(f"{key}={_lua_value(value)}" for key, value in sorted(caps.items())) + "}"
        (scripts / "main.lua").write_bytes(main.replace(marker, "local Capabilities = " + text).encode("utf-8"))
        (dest / "enabled.txt").write_bytes(b"")
        files = [{"path": p.relative_to(out).as_posix(), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                 for p in sorted(p for p in dest.rglob("*") if p.is_file())]
        manifest = {"status": "release", "mod": MOD, "version": spec["version"],
                    "game_build": spec["game_build"], "ue4ss": spec["ue4ss"],
                    "capabilities": caps, "files": files}
        (out / "release-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return manifest
    except BaseException:
        shutil.rmtree(out)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = build(args.out)
    print(f"Built {len(result['files'])} UE4SS files for {result['version']}: {args.out}")
