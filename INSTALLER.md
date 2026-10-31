# 安装器适配

普通源码构建输出同名 `.pak/.utoc/.ucas` 三件套，可按 [README](README.md) 手动安装。

`package.py` 为“影之刃零 模组安装器”的签名发行协议提供可选适配。需要另行取得安装器作者工具 `pbz-pack.exe` 和自己的发布密钥；它们不是构建或手动安装的依赖，也不包含在本仓库中。

```powershell
python package.py --build .local/build-0.2.7-preview --packer "<pbz-pack.exe路径>" --key "<发布私钥路径>" --out .local/releases/PbzModConfig-0.2.7-preview.zip
```

打包前检查三件套哈希、唯一原版覆盖清单及演示排除标记。版本来自 `src/Metadata.js`，包描述来自 [release-spec.json](release-spec.json)。当前打包通道为 `preview`。

派生版本应使用自己的模组标识、作者信息和签名身份，并按安装器的信任流程发布；本项目不会提供原作者的私钥。

玩家使用签名包时，应把完整 ZIP 导入安装器。手动安装过旧版的玩家，应先备份并移走本框架的旧三件套，再导入新包，避免安装器卸载时恢复旧的手动文件。卸载保留业务模组与用户配置。
