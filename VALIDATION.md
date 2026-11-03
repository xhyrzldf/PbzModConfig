## 0.3.10

The complete code review passed and all 192 JavaScript checks passed. On Steam build 26266538, opening and closing the menu, loading a save from settings, returning to the title screen, continuing, and reopening the menu were tested successfully. The release payload differs from the tested candidate only in its version string. Automated checks and an offline build are repeated for this public source export.

Fault records are bounded in memory. This version adds no automatic diagnostic file writes, background performance sampler, or diagnostic network requests. Records are lost when the game process exits. Existing historical diagnostic files may be attached through installer feedback. Continuous frame-time and memory measurements were not performed; this coverage does not establish performance on every system.

## 0.3.9

八语言切换、原生越南语选项字体和框架回归通过。发行载荷与独立构建逐文件比较；游戏内字形、布局和控制器行为未在本版实测。

## 0.3.8

121项脚本回归通过。箭头测试按原生父子层级比较点击位置；覆盖临时背景音量、错误回滚、偏好更新、重复停止、提供者注销与重入交接。游戏内声音、图标融合及音量恢复尚待确认；不将播放编号当作可听性证明。

## 0.3.7

117项脚本和13项Python检查通过。修复非画布宿主被错误模拟为画布的问题，按真实槽接口验证试听行；覆盖预览键清单、颜色子项、资源释放和30／60／126／240帧输入。新增导航状态按轴独立，模拟轴与合成方向键共享重复节流。游戏内布局和实体手柄操作待确认。

## 0.3.6

111项脚本和13项Python检查通过；预览使用原生形状夹具验证，真实游戏布局、鼠标命中和暂停时可听性尚待验证。

## 0.3.5

Correct the signed package channel from preview to stable so the installer offers the official release. Retains 0.3.4's native slider layout: current value when unselected, minimum and maximum endpoints plus a thumb-following value when adjusting. Percentage, integer and color values update immediately. Runtime behavior and existing settings are unchanged.

Automated checks are recorded during preparation. In-game coverage remains limited to the release acceptance evidence.

## 0.3.4

Restore the native slider value layout: unselected rows show the current value; selected rows show minimum and maximum endpoints with a separate value following the thumb. Percentage, integer and color-channel values update with mouse, keyboard and controller input. Existing settings are preserved.

Automated checks are recorded during preparation. In-game coverage remains limited to the release acceptance evidence.

## 0.3.2 · 2026-11-01

- 修复键盘和手柄绑定值空白、点击设置行无法录入的问题。
- Windows录入不再误加Cmd；支持Ctrl、Alt、Shift组合键。此前误存的绑定需重新录入。
- 移除动作行多余的箭头和下划线；保留现有配置格式。
- 99项脚本回归通过；游戏内显示和实际输入仍待玩家确认。

# 验证范围

## 0.3.0 · 2026-11-01

新增快捷键、颜色与声音组件。脚本回归92项、构建与打包回归12项通过，独立审核通过。旧框架兼容、配置保留、取消与菜单关闭清理均有回归；新增组件的实际字形、手柄、音频和游戏内体验尚未验证。版本定名仅改变元数据，未将命名变化当作实机验收。

## 0.2.9-preview历史验证

版本：`0.2.9-preview`。目标构建：Steam `26266538`。

## 已有验证

- 原生模组页签、文字、图标、模组版本与作者信息已有游戏内显示验证。
- 配置保存后端已有游戏内同进程写入、回读及重建日志实例后的恢复验证。
- 离线测试覆盖协议所有权、重复注册、旧句柄、异常隔离、配置校验、订阅、双槽日志及界面适配夹具。
- 安装器既有发行流程已验证签名导入、升级、启停、卸载以及中文名和版本显示。

独立源码仓库运行协议、适配器和原生输入 JavaScript 测试及 Python 构建、打包测试。使用本地原版脚本与外部打包工具完成三件套离线构建。此轮源码同步没有运行游戏。

0.2.6 的 Z／C 切页修复已有玩家游戏内反馈确认；输入夹具覆盖 Z／C、LT／RT 放行及原有配置操作，不能替代完整手柄专项实测。

0.2.7 的中文与主播模式下语言显示、模组名称与分组标题左对齐已有游戏内反馈确认。新增离线夹具覆盖原生文本优先、引擎语言回退、加载期间保留语言和实际标题行绑定。

## 尚未完整验证

- 当前版本全部鼠标、键盘和手柄操作、肩键导航及弹窗返回组合。
- 跨游戏进程保存恢复，权限不足、损坏和中断写入的游戏内表现。
- 所有业务模组的组合、全部游戏区域及其他游戏构建。
- 与其他覆盖 `SettingPanel.js` 的配置菜单同时安装。

源码检查和离线夹具不能代替这些游戏内验证。移植构建入口不改变运行时代码，本次源码发布不新增游戏兼容性承诺。

0.2.9 的韩语语言选项显示及鼠标切换到俄语已在游戏中检查；跨进程配置恢复已随地图改键验证。七种语言所有菜单、所有实体手柄组合仍未完整验收。新增离线测试覆盖选项文字按字库切换及保留原生字号、材质与描边。
