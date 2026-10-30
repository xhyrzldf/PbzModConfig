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

## 保存与恢复

`ConfigStore` 初始化只调用一次 `storage.load()`；普通变更 250 毫秒去抖，连续拖动最长 1500 毫秒保存一次。关闭、释放显式 flush。保存归业务，框架没有自己的业务值文件。

`Journal` 将 `{format:1,modId,generation,schemaVersion,revision,values}` URI 编码后放在单行 CSV。两个独立目录各含 `New_CSV.csv`。完整性校验用于发现损坏，不用于防篡改。每次写非当前槽，回读校验通过才推进代际；不声称具备操作系统断电原子性。写前重读代际，另一个进程或手工修改时阻止覆盖，不自动覆盖运行中的内存。

损坏时可从完整的最高代际读取，但禁止自动覆写损坏槽。诊断保留原件；关闭业务后先备份完整目录，再由恢复工具生成新的两槽副本并核对，最后人工替换。若没有有效文件，只使用内存默认值，保存保持失败。未知键、越界值或新于当前的版本不会静默清洗；旧版本必须显式提供 `migrate(record,targetVersion)`。新增缺省字段可补默认。

**当前状态：跨进程保存已由 Node.js 测试进程验证；游戏内同进程写入与回读已有验证，跨游戏进程恢复仍待验证。Node.js 文件接口只存在于测试和维护工具中，不属于游戏运行时依赖。**
