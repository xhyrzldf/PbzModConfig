# 多语言接入

框架0.2.9-preview提供简中、英文、繁中、韩语、俄语、西班牙西语和拉美西语；演示提供者仍为中英。框架优先识别原生菜单实际显示文字，再回退 `GetCurrentLanguage()`，西语地区另以原生差异词条区分。框架没有独立语言设置，也不往业务配置中保存语言。设置面板存在期间每500毫秒核对一次；变化后重新解析标题、说明、分组、选项、禁用原因、按钮及保存提示。真正关闭面板后释放观察器；重新打开读取当前语言及业务当前状态，不重新读盘。

## 接入模组怎么写

将 `provider/Translations.js` 和所需的提供者模板复制到业务模组自己的私有目录。它只整理普通文本数据，不引用 `PbzModConfig`，框架未安装时也能加载。

```javascript
const { createTranslations } = require("./Translations");
const T = createTranslations({
    zhHans: {
        title: "示例模组", enabled: "启用", placement: "位置",
        left: "左侧", right: "右侧", needsEnabled: "请先启用"
    },
    en: {
        title: "Example mod", enabled: "Enabled", placement: "Position",
        left: "Left", right: "Right", needsEnabled: "Enable this mod first."
    }
});

// 将下面的条目放入已有描述的 entries 数组。
const position = {
    key: "placement", type: "choice", label: T.placement,
    defaultValue: "right",
    options: [
        { value: "left", label: T.left },
        { value: "right", label: T.right }
    ],
    enabledWhen: { key: "enabled", equals: true },
    disabledReason: T.needsEnabled
};
```

描述的 `displayName`、分组 `label`、条目 `label/description/disabledReason`、枚举选项 `label` 都接受这些文本表。标题或动作也用相同写法。保持 `modId`、`group.id`、`entry.key`、枚举 `value` 不变；菜单在显示时解析语言，`placement="right"` 不会因切语言变成另一项配置。

新增语言只需在 `createTranslations` 的对象中补一个语言目录，例如 `ja: { title: "...", enabled: "...", ... }`，重新构建该业务模组。框架无需认识该模组的词条，也无需修改控件或协议。游戏中的地区别名会归一，例如 `en-US → en`、`zh-CN → zhHans`、`ja-JP → ja`。缺词条时按英语、简体中文、首个可用文本回退，不显示内部配置键。

框架公共文案入口在[LocaleStrings.js](src/LocaleStrings.js)。公共文案作为独立模块随框架构建，不引用其他模组文件。演示业务文案在[Translations.js](demo/Translations.js)，提供者仍应携带自己的词表。没有对应翻译的提供者会回退显示，不宣称整个第三方模组已有对应语言支持。

语言标签保留地区差异：`zh-Hant / zh-TW → zhHant`、`ko-KR → ko`、`ru-RU → ru`、`es / es-ES → es-ES`、`es-MX / es-419 → es-419`。

## 英文写法

能核实的游戏原生术语使用原词；没有原词时，按英语玩家习惯独立写文案，不逐字翻译中文。按钮使用简短动词，说明直接描述效果或操作，错误提示说明玩家需要知道的状态，不堆实现细节。现有示例采用 `Mods`、`Opacity`、`Save now`、`Reset to defaults` 等常见表达；尚未逐词核实为本作官方英译的词不冒充官方术语。

交付词条不等于游戏中切语言实测通过。中英文完整显示、弹窗、数值格式及切换后的焦点仍需用户游戏内确认。
