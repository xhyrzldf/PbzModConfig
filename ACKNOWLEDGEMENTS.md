# 来源与外部工具

## 界面实现参考

原生控件生命周期、页签导航及委托清理参考了 xyzkljl1 的 [Mod Config UI](https://www.nexusmods.com/phantombladezero/mods/86) 和 [MyPBZMod 源码](https://github.com/xyzkljl1/MyPBZMod/tree/2944a05fe1f769b44b9ff71396c959c658681d94/ModConfigUI)。参考版本固定到提交 `2944a05fe1f769b44b9ff71396c959c658681d94`。

该项目使用 UE4SS Lua，本项目使用游戏内的 PuerTS JavaScript。这里没有包含其 Lua 源码或资产；其许可证不由本项目的 MIT 许可证替代。

## 构建工具

- repak 0.2.3：打包 V11 格式的 `.pak`。
- retoc 0.1.5：生成 UE5_7 格式的 `.utoc/.ucas`。

这些工具须单独安装，本仓库不分发其程序或代码。

## 游戏内容

游戏原生控件、字体、材质及其他资源由游戏提供，本仓库只保留运行时所需的资源路径与接口引用。原版 `SettingPanel.js` 由构建者在本地提供，不随源码分发；MIT 许可证只适用于本仓库的项目文件。
