模组配置菜单 1.0.3
作者 皮一下就很凡@Bilibili

修复与其他设置菜单共存时的标签消失、按钮重建和关闭清理问题。已与 Mods Menu 0.9.3 验证 F9 打开、标签切换及关闭后重开。

点“恢复已删除图标”后，按钮会直接显示恢复数量或“暂无可恢复图标”。此功能需搭配地图收集追踪 1.0.7。

适用《影之刃零》Steam 构建 26367565，需要 UE4SS #5 1.0.3。
获取前置：https://www.nexusmods.com/phantombladezero/mods/5

退出游戏后安装，保留已有配置。手动从 JavaScript 版更新时，移走 ProjectPBZ/PBZModLoader/mods/pbz-mod-config/；如有更早版的 zzz_PBZModConfig_P.pak、.utoc、.ucas，也一并移出 ProjectPBZ/Content/Paks/~mods/。将新包 platform 文件夹合并到游戏根目录。

卸载时退出游戏，删除 platform/steam/ue4ss/Mods/PbzModConfig/，保留配置及其他模组仍需的共享前置。
