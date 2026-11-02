# PbzModConfig · 影之刃零模组配置菜单

在游戏原生设置中增加「模组」页签，为接入的模组提供统一的配置界面。

**版本：0.3.6** · **目标游戏构建：Steam 26266538 / UE 5.7.4**

作者：[皮一下就很凡@Bilibili](https://space.bilibili.com/26786884)

## 功能

音色选择与试听合为一行；颜色编辑增加调色盘与前后对比；支持接入模组的右侧即时预览。保留协议1、旧模组与保存值。新增界面及暂停菜单试听尚待游戏内验证。

- 原生设置页签、列表与说明区，支持折叠分组、开关、数值滑条、枚举、动作和恢复默认。
- 支持直接录入快捷键、颜色编辑及音效选择／试听；现有提供者与保存格式继续兼容。详见[扩展示例](demo/ExtendedProvider.js)。
- 简中、英文、繁中、韩语、俄语及两区西语跟随游戏语言切换，提供独立的模组翻译表。
- 接入方自己管理配置；配置菜单没有安装时，业务模组仍可正常加载。
- 提供变更订阅、条件显示、禁用原因、错误隔离和保存状态。
- 配置使用两个交替写入的槽位，带校验、回读及外部改动检测；另附离线恢复工具。

从0.3.0起不再使用preview版本后缀。新增组件尚未完成游戏内验收。菜单显示已有游戏内验证，完整手柄操作、异常读写、跨游戏进程恢复等仍待补齐，见 [验证范围](VALIDATION.md)。只针对上述游戏构建，不承诺其他版本兼容。

## 给模组作者

将所需的 `provider/` 文件复制到你的模组私有目录，调整相对引用，再初始化配置仓库并发布描述。接入方不要直接引用 `PbzModConfig/...`，避免把菜单变成运行时必装依赖。

- [接入协议](PROTOCOL.md)：描述结构、控件、读写、订阅、保存与恢复。
- [完整接入示例](demo/DemoProvider.js)：独立仓库和可选注册；演示不会进入玩家构建。
- [多语言接入](LOCALIZATION.md)：翻译表与稳定配置值。
- [运行时边界](RUNTIME.md)：原生界面适配与保存后端。

## 从源码构建

需要 Python 3.10+、Node.js，以及单独安装的 repak、retoc。已用 repak 0.2.3、retoc 0.1.5 构建；工具本体不包含在仓库中。项目没有额外的 Python 或 npm 包依赖。

你还需要从自己的游戏安装中取得构建 `26266538` 对应的 `SettingPanel.js`，放在以下相对路径：

```text
<脚本导出根目录>/ProjectPBZ/Content/JavaScript/UI/Setting/SettingPanel.js
```

构建会核对原版脚本的 SHA-256 和补丁锚点。游戏原版脚本、解包资源、构建产物及签名密钥都不包含在此仓库中。

在仓库根目录执行（替换示例路径）：

```powershell
python build.py --source-root "<脚本导出根目录>" --game-root "<游戏安装目录>" --repak "<repak.exe路径>" --retoc "<retoc.exe路径>" --out .local/build-0.3.6
```

输出是 `zzz_PBZModConfig_P.pak/.utoc/.ucas` 三件套及哈希清单。输出必须位于本仓库 `.local/` 下的新子目录；脚本不会安装模组，也不会覆盖旧构建。

只做源码暂存和语法校验时，可省略两个打包工具，使用：

```powershell
python build.py --source-root "<脚本导出根目录>" --out .local/stage-check --stage-only
```

本模组仅覆盖 `ProjectPBZ/Content/JavaScript/UI/Setting/SettingPanel.js`，其他代码位于独立的 `PbzModConfig/` 目录。其他覆盖同一设置脚本的模组可能冲突；未验证与 Mod Config UI 同时安装。

## 安装与卸载

退出游戏，备份现有模组及存档，将构建生成的同名三件套一并放入游戏的 `ProjectPBZ/Content/Paks/~mods/`。启动后打开「设置 → 模组」；只有实际接入的模组会显示配置项。运行时不需要 Node.js、Python 或 UE4SS。

升级前先移走本框架的旧三件套，避免多个版本同时加载。卸载时只移除 `zzz_PBZModConfig_P.pak/.utoc/.ucas`，业务模组及其配置会保留。

配置和诊断位于用户文档目录的 `PbzMods/Config/`。诊断文件为 `PbzModConfig/diagnostics/New_CSV.csv`，其中存放 JSON 文本。使用安装器的签名包见 [安装器适配](INSTALLER.md)。

## 开发检查

```powershell
node --test tests/core.test.cjs tests/adapters.test.cjs tests/native-input.test.cjs tests/native-language.test.cjs tests/native-choice-font.test.cjs
python -m unittest discover -s tests -p "test_*.py"
```

离线测试覆盖协议、配置仓库、保存日志、界面适配夹具和构建边界，不能替代游戏内验证。

## 许可与参考

本项目使用 [MIT 许可证](LICENSE)。参考资料和外部构建工具见 [来源说明](ACKNOWLEDGEMENTS.md)。
