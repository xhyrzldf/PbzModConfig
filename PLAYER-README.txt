模组配置菜单 0.2.5-preview
作者：皮一下就很凡@Bilibili
适用：影之刃零 Steam 构建 26266538

退出游戏后，将完整签名 ZIP 导入“影之刃零 模组安装器”。
手动安装时，将 zzz_PBZModConfig_P.pak、.utoc、.ucas 三件套一并放入
游戏的 ProjectPBZ/Content/Paks/~mods/ 目录。

启动游戏，打开“设置 → 模组”。只有已接入的模组会显示配置项。
升级前备份并移走手动安装的本框架旧三件套，不要改动其他模组。
卸载时仅移除本框架三件套，配置和业务模组会保留。

这是预览版本。完整手柄操作、跨游戏进程恢复和异常读写仍待验证。
其他覆盖 SettingPanel.js 的模组可能冲突。
不需要 UE4SS、Node.js 或 Python 作为游戏运行依赖。
