# PbzModConfig · 影之刃零模组配置菜单

在游戏原生设置中增加「模组」页签，为接入的模组提供统一配置界面。

**版本：1.0.4** · **目标游戏构建：Steam 26367565** · **前置：UE4SS #5 1.0.3**

作者：[皮一下就很凡@Bilibili](https://space.bilibili.com/26786884)

1.0.0 从 JavaScript 版迁移到 UE4SS Lua，沿用模组身份并保留原有设置。游戏内支持的控件包括开关、滑条、选项、快捷键、颜色及确认操作。游戏内测试范围见 [验证记录](VALIDATION.md)。

在地图收集追踪 1.0.7 中点击“恢复已删除图标”，按钮会显示恢复数量或“暂无可恢复图标”。

1.0.3 修复与其他设置菜单共存时的标签消失、按钮重建和关闭清理问题。已与 Mods Menu 0.9.3 共同安装验证 F9 打开、双方及原生标签切换、关闭后重开。

1.0.4 修复在游戏设置的“模组”页点击分组小标题会导致游戏闪退的问题。

## 安装与更新

先退出游戏并备份配置。安装 [UE4SS #5 1.0.3](https://www.nexusmods.com/phantombladezero/mods/5)，然后将本模组安装到 `platform/steam/ue4ss/Mods/PbzModConfig/`。从 JavaScript 版手动升级时，移走旧的 `ProjectPBZ/PBZModLoader/mods/pbz-mod-config/`；更早版如有 `zzz_PBZModConfig_P.pak/.utoc/.ucas`，也移出 `ProjectPBZ/Content/Paks/~mods/`。保留配置和其他模组仍需的前置。

## 从源码构建

需要 Python 3 和 Node.js，不需要提取游戏脚本。源码位于 `ue4ss/` 和 `lua/`，图片位于 `assets/`。

```powershell
python build_ue4ss.py --out .local/build-1.0.4
```

构建只写入仓库 `.local/` 下的新目录，不安装游戏文件。生成的 `release-manifest.json` 记录版本和逐文件哈希。

仓库中 `src/`、`provider/`、`native/` 与 `loader/` 保留旧版 JavaScript 代码，供查阅历史；当前发行版使用 Lua。旧版接口文档保留并注明适用范围。

`package.py` 保留旧版打包实现；当前 UE4SS 版使用上面的独立构建入口。

## 许可

本项目使用 [MIT 许可证](LICENSE)。`vendor/dkjson.lua` 保留其原有 MIT 许可说明；参考项目及其他来源见 [来源说明](ACKNOWLEDGEMENTS.md)。
