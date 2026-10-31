"use strict";
const { words } = require("./LocaleStrings");
function language(value) {
    const v = String(value || "en").replace(/_/g, "-").toLowerCase();
    if (["zhs", "zhhans", "zh-cn", "zh-sg", "zh-hans", "zh"].includes(v)) return "zhHans";
    if (["zht", "zhhant", "zh-tw", "zh-hk", "zh-mo", "zh-hant"].includes(v)) return "zhHant";
    return v.split("-")[0];
}
function gameLanguage(UE, previous = "zhHans") {
    // PBZ streamer mode can report an engine language different from the text
    // actually rendered by the native menu. Resolve through that same path first.
    try {
        const text = String(UE.KismetTextLibrary.Conv_TextToString(UE.PBZBlueprintFunctionLibrary.MakeTextByKey("UI_StartMenu_01"))).trim();
        if (text === "新游戏") return "zhHans";
        if (text === "新遊戲") return "zhHant";
        if (text.toUpperCase() === "NEW GAME") return "en";
    } catch (_) { /* Native text may be unavailable while the world is loading. */ }
    try {
        const value = UE.KismetInternationalizationLibrary.GetCurrentLanguage();
        if (typeof value === "string" && /^[a-z]{2,3}(?:[-_][a-z0-9]{2,8})*$/i.test(value.trim())) return language(value.trim());
    } catch (_) { /* Preserve the last known language until the next refresh. */ }
    return previous;
}
function resolve(value, locale) {
    if (value === undefined) return "";
    if (typeof value === "string") return value;
    const normalized = {};
    for (const [key, text] of Object.entries(value)) normalized[language(key)] = text;
    return normalized[language(locale)] ?? normalized.en ?? normalized.zhHans ?? Object.values(normalized)[0] ?? "";
}
function format(value, entry, locale) {
    if (entry.type === "toggle") return resolve(value ? words.on : words.off, locale);
    if (entry.type === "choice") return resolve(entry.options.find(o => o.value === value)?.label, locale);
    if (entry.type === "number") {
        const f = entry.format || "F0", percent = f[0] === "P";
        const digits = Number(f[1]);
        if (typeof Intl !== "undefined" && typeof Intl.NumberFormat === "function") {
            const tag = locale === "zhHans" ? "zh-Hans" : locale === "zhHant" ? "zh-Hant" : locale;
            return new Intl.NumberFormat(tag, { style: percent ? "percent" : "decimal", minimumFractionDigits: digits, maximumFractionDigits: digits, useGrouping: false }).format(value);
        }
        return (value * (percent ? 100 : 1)).toFixed(digits) + (percent ? "%" : "");
    }
    return "";
}
module.exports = { language, gameLanguage, resolve, format };
