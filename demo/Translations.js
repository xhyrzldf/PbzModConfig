"use strict";
const { createTranslations } = require("../provider/Translations");
// These catalogs belong to the provider; the optional menu resolves them at display time.
// A new language needs only another catalog. Keep descriptor keys and enum values stable.
module.exports = createTranslations({
    zhHans: {
        title: "配置演示", display: "显示", enabled: "启用演示",
        enabledHelp: "关闭后，透明度设置暂时不可调整。", opacity: "透明度",
        opacityHelp: "以 5% 为一级调整。更改会自动保存。", disabled: "请先启用演示",
        placement: "位置", left: "左侧", right: "右侧", saving: "保存", save: "立即保存"
    },
    en: {
        title: "Demo settings", display: "Display", enabled: "Enable demo",
        enabledHelp: "Lets you adjust opacity.", opacity: "Opacity",
        opacityHelp: "Adjust opacity in 5% increments. Changes are saved automatically.", disabled: "Enable the demo to adjust opacity.",
        placement: "Position", left: "Left", right: "Right", saving: "Saving", save: "Save now"
    }
});
