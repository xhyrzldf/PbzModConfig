> 本文件描述 0.3.13 及以前的 JavaScript 版，1.0.0 的 UE4SS 版请看 [README](README.md)。

# 运行时边界

目标构建为 Steam `26266538`，UE `5.7.4`。脚本通过游戏现有的 PuerTS 上下文运行。

## 原生设置

当前反射接口可创建设置集合和原生行，但没有暴露完整的 `AddSetting`、`SetDynamicGetter`、`SetDynamicSetter` 及注册接口。因此集合只承担页签身份，具体配置通过独立的原生行适配器展示。

页签、导航元数据和集合按索引成对维护。焦点等待原生行就绪后处理；弹窗覆盖与真正关闭分别处理。清理时仅解除本框架自己的监听，避免影响原生设置和其他模组。

本作不将普通 JavaScript 字符串隐式转换为 `FText`，界面文字统一显式转换。

## 配置保存

配置由业务模组持有，菜单只调用其描述中的读写接口。正式运行不依赖 Node.js 或开发探针。

用户目录通过 `KismetSystemLibrary.GetPlatformUserDir()` 获取。EasyCsv 后端使用真实的 TArray/TMap 和 `$ref()`；CSV 行名按 FName 的大小写表现读取，不将反射容器当作普通 JavaScript 对象。

双槽日志提供代际、校验和写后回读，不承诺断电原子性。跨游戏进程恢复、权限失败和损坏场景仍须在游戏中验证，详见 [验证范围](VALIDATION.md)。
