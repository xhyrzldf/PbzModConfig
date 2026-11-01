# PbzModConfig 协议 1.0

协议版本：1.0。主版本槽位 `globalThis.__PBZ_MOD_CONFIG_V1__`。只支持同一 PuerTS 上下文，其他上下文不会自动发现。

## 所有权与发布

业务先初始化自己的仓库，再发布描述；菜单加载、打开、关闭均不读磁盘。`provider/` 是可复制到业务私有模块空间的原创适配模板，不要求业务引用本包。复制后必须修改包内路径前缀，不能覆盖框架的文件。

`getHub(root).publish(descriptor)` 返回 `{ownerToken, dispose}`。同 `modId` 替换；token 是不透明对象身份，只在本进程有效。旧注销不撤销新实例。`publishOptional` 捕获协议冲突并返回错误，不能因注册失败停止业务。目录字段与方法沿用提案：`protocol`、`providers`、`subscribeProviders`、`snapshotProviders`；接入方不可直接改写 Map。事件是 `{type:"published"|"removed", record, previous?}`。通知可同步重入，监听者需校验当前 token。

描述包含 `apiVersion:1, modId, modVersion, schemaVersion, displayName, groups, entries` 及 `read/apply/subscribe/reset/flush`，动作需要 `invokeAction`。标识符由英文字母开头、后续字母数字、点、下划线或短横线组成，最长 96 字符。描述元数据只包含普通数据，发布后不可修改；更新描述通过重新发布。

## 读写

- `read()` 返回 `{revision,values,persistence}`，revision 为非负安全整数，values 为扁平键及布尔、有限数值、稳定字符串。没有 UObject、文件句柄、闭包或世界引用。
- `apply(patch,{baseRevision?,origin})` 整批校验，过期返回 `REVISION_CONFLICT`；失败不改内存。相同值不递增、不广播。成功更新内存后广播，保存去抖独立发生。
- `subscribe(listener)` 返回只解除该监听的函数；事件是快照加 `origin`，也包含保存状态更新。订阅者只更新显示，不反写同值。框架先订阅再读取。
- `reset(groupId?,context?)` 一次批量恢复本模组或本组默认，支持修订冲突。确认弹窗由界面负责，确认回调仍校验 token 和修订号。
- `flush()` 同步返回当前保存结果。`invokeAction(key,context?)` 同步执行一个具名动作。首版不接受 Promise。
- 写入和动作结果至少含 `ok, revision, values, persistence`；失败另含 `error`，字段错误在 `fields`。`ok:true` 表示内存变更成功，只有 `persistence.state === "saved"` 表示保存成功。
- `persistence.state` 为 `saved/pending/failed`，失败附 `error`。提供者销毁前保存失败时仍保留所有权，允许重试；菜单卸载只解除自己的订阅，不销毁业务仓库。

## 控件

`toggle` 为布尔；`number` 提供有限 `min/max/step`，步长以 min 为起点，校验不暗中截断；`format` 为 `F0…F6` 或 `P0…P6`。`choice` 使用 `{value,label}[]`，value 是稳定字符串。`header` 与 `action` 不存值。未知控件跳过并诊断；其他描述错误隔离该提供者。

分组为 `{id,label,order?}`，条目可引用 `group`。`enabledWhen/visibleWhen` 第一版固定为 `{key,equals}`，不执行任意谓词。隐藏值保留，禁用原因由 `disabledReason` 提供。业务自身的 `apply` 可更新隐藏或禁用项；菜单在提交前重新检查条件。`applyMode` 首版只允许 `immediate`。

标签、说明、分组、选项名为字符串或语言字典。界面渲染时解析，`zhHans/zh-Hans/zh-CN/zhs` 等统一，繁中独立；回退顺序是当前语言、英文、简中、字典首值。空说明保持空。

## 0.3.0 可选组件扩展

`apiVersion`、共享总线槽位及保存格式仍为 1。已有提供者继续使用原来的私有接入代码即可，不需要改字段、换配置目录或执行迁移。只有要使用新组件的作者才需要把新版 `provider/` 全部复制到自己的私有目录，仍通过 `publishOptional(store)` 注册。不要覆盖其他模组的接入层。

| 类型 | 保存值 | 描述字段与交互 |
| --- | --- | --- |
| `keybind` | `"Ctrl+Shift+G"`、`"Gamepad_FaceButton_Left"` 或空字符串 | 点击后录入；修饰键顺序固定 `Ctrl/Alt/Shift/Cmd`。按键名使用引擎稳定名。`allowModifiers/allowMouse/allowGamepad/allowUnbound` 默认均为 true；可用 `allowedKeys/reservedKeys` 限定主键。Esc 和手柄返回键保留给取消。 |
| `color` | `"#RRGGBB"`；`alpha:true` 时 `"#RRGGBBAA"` | 8 位 sRGB 通道；原生滑条编辑草稿、色块预览、确认／取消。确认前不触发业务回调或保存。 |
| `sound` | 选项稳定字符串，如 `"bell"` | `options:[{value,label}]` 与 `choice` 一致；另提供试听。音量、静音分别组合现有 `number/toggle`。 |

快捷键冲突仅检查**当前提供者**同一 `conflictGroup` 中完全相同的绑定，默认分组为 `default`；`conflictGroup:false` 允许复用。不同模组、游戏原生输入及不同设备间的语义冲突不在检查范围。框架负责编辑和保存，**不注册业务热键处理器**。业务模组自行读取配置并执行功能；复用绑定时应明确上下文。录入仅占用当前编辑会话，结束后恢复原有菜单输入。鼠标滚轮、模拟轴与多键序列不属于本版录入能力。

颜色和快捷键编辑会话绑定提供者 token 与 revision。提供者更换、配置外部变更、隐藏／禁用、切页或关闭时撤销未提交内容。颜色通道是 0–255 整数，不保存引擎颜色对象。

`createStore` 可传 `options.sounds = { [entryKey]: (selectedId) => stop }`。回调必须同步返回可调用的停止函数；由业务模组创建、持有和释放音频，异常前自行清理已创建资源。没有文件选择器，不加载任意本地音频；资源须来自业务模组可用的运行时资源。完整示例见 `demo/ExtendedProvider.js`。

手写提供者可实现 `previewSound(key,{baseRevision}) -> {ok:true,stop}`，失败返回 `{ok:false,error}`，不接受 Promise。试听不得写配置；停止函数应幂等。框架只允许一段试听，切换、关闭、提供者注销或失效时停止；菜单额外提供五秒上限。直接调用提供者接口的业务方仍负责调用返回的 `stop()`。

**旧框架降级**：`publishOptional` 为含新类型的提供者发布基础视图，附加可选 `getExtendedDescriptor(1)`。新版框架获取完整描述；旧框架只能看到旧控件及升级提示。依赖新字段条件的旧行也隐藏，避免断裂条件。快照、订阅和操作返回值投影为可见字段；恢复默认只提交投影中的缺省值，不调用完整重置。新字段和依赖项仍由原业务仓库持有，完全保留。不要绕开 `publishOptional` 直接向旧总线发布含新控件的完整描述。

这个降级保证针对**框架版本**：若业务模组自身回退到不认识新字段的旧代码，仍按既有保存合同拒绝未知字段并保留原文件，不承诺自动迁移或删除数据。业务作者不能把已有字段直接改成另一种类型而期待无迁移升级；需保留旧键或自行提供明确迁移。

## 保存与恢复

`ConfigStore` 初始化只调用一次 `storage.load()`；普通变更 250 毫秒去抖，连续拖动最长 1500 毫秒保存一次。关闭、释放显式 flush。保存归业务，框架没有自己的业务值文件。

`Journal` 将 `{format:1,modId,generation,schemaVersion,revision,values}` URI 编码后放在单行 CSV。两个独立目录各含 `New_CSV.csv`。完整性校验用于发现损坏，不用于防篡改。每次写非当前槽，回读校验通过才推进代际；不声称具备操作系统断电原子性。写前重读代际，另一个进程或手工修改时阻止覆盖，不自动覆盖运行中的内存。

损坏时可从完整的最高代际读取，但禁止自动覆写损坏槽。诊断保留原件；关闭业务后先备份完整目录，再由恢复工具生成新的两槽副本并核对，最后人工替换。若没有有效文件，只使用内存默认值，保存保持失败。未知键、越界值或新于当前的版本不会静默清洗；旧版本必须显式提供 `migrate(record,targetVersion)`。新增缺省字段可补默认。

**当前状态：跨进程保存已由 Node.js 测试进程验证；游戏内同进程写入与回读已有验证，跨游戏进程恢复仍待验证。Node.js 文件接口只存在于测试和维护工具中，不属于游戏运行时依赖。**
