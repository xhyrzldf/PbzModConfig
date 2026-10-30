# 模组页签图标

`modconfig-icon.png` 是 128×128 的透明背景齿轮图标，用于设置页中的模组页签。

运行时从包内读取 PNG，通过游戏的 `KismetRenderingLibrary.ImportFileAsTexture2D` 创建纹理。导入失败时记录 `CUSTOM_ICON_FAILED`，并保留可用的原生设置图标。
