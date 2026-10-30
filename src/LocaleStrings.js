"use strict";
const { createTranslations } = require("../provider/Translations");
// Add a language catalog here. Controls and persisted values never depend on translated text.
const catalogs = {
    zhHans: {
        tab: "模组", reset: "恢复默认", confirm: "恢复此模组的默认设置？",
        unavailable: "暂不可用", empty: "暂无可配置的模组",
        failed: "保存失败，当前更改尚未写入文件。", pending: "正在保存…", off: "关闭", on: "开启",
        expand: "展开", collapse: "收起", version: "版本", author: "作者："
    },
    en: {
        tab: "Mods", reset: "Reset to defaults", confirm: "Reset this mod's settings to their defaults?",
        unavailable: "Unavailable", empty: "No mod settings available",
        failed: "Couldn't save your changes.", pending: "Saving…", off: "Off", on: "On",
        expand: "Expand", collapse: "Collapse", version: "Version", author: "By "
    }
};
module.exports = { words: createTranslations(catalogs) };
