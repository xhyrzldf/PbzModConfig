"use strict";
// Stable scalar encodings: no engine objects or translated names in saved values.
const EXTENDED = new Set(["keybind", "color", "sound"]);
const MODIFIERS = ["Ctrl", "Alt", "Shift", "Cmd"];
const MODIFIER_KEYS = new Set(["LeftControl", "RightControl", "LeftAlt", "RightAlt", "LeftShift", "RightShift", "LeftCommand", "RightCommand"]);
function bindingError(entry, value) {
    if (typeof value !== "string") return "EXPECTED_BINDING";
    if (!value) return entry.allowUnbound === false ? "BINDING_REQUIRED" : null;
    const parts = value.split("+"), key = parts.pop();
    if (!/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(key) || MODIFIER_KEYS.has(key) || MODIFIERS.includes(key)) return "INVALID_KEY";
    if (parts.some((p, i) => !MODIFIERS.includes(p) || (i && MODIFIERS.indexOf(parts[i - 1]) >= MODIFIERS.indexOf(p)))) return "INVALID_MODIFIERS";
    if (parts.length && entry.allowModifiers === false) return "MODIFIERS_DISABLED";
    if (/^Gamepad_/.test(key) && (entry.allowGamepad === false || parts.length)) return "GAMEPAD_BINDING_DISABLED";
    if (/(?:MouseButton\d*|MouseScrollUp|MouseScrollDown)$/.test(key) && entry.allowMouse === false) return "MOUSE_BINDING_DISABLED";
    if (["Escape", "Gamepad_FaceButton_Right", ...(entry.reservedKeys || [])].includes(key)) return "RESERVED_KEY";
    if (entry.allowedKeys && !entry.allowedKeys.includes(key)) return "KEY_NOT_ALLOWED";
    return null;
}
function chord(key, modifiers = {}) {
    return [...MODIFIERS.filter(m => modifiers[m]), key].join("+");
}
function colorError(entry, value) {
    return typeof value === "string" && (entry.alpha ? /^#[0-9A-Fa-f]{8}$/ : /^#[0-9A-Fa-f]{6}$/).test(value) ? null : "INVALID_COLOR";
}
function colorChannels(value) { return value.slice(1).match(/../g).map(v => parseInt(v, 16)); }
function colorValue(channels) { return "#" + channels.map(v => Math.round(v).toString(16).padStart(2, "0")).join("").toUpperCase(); }
function conflicts(schema, values) {
    const used = new Map(), errors = {};
    for (const [key, entry] of schema.values) {
        if (entry.type !== "keybind" || !values[key] || entry.conflictGroup === false) continue;
        const token = (entry.conflictGroup || "default") + ":" + values[key];
        if (used.has(token)) { errors[key] = "BINDING_CONFLICT"; errors[used.get(token)] = "BINDING_CONFLICT"; }
        else used.set(token, key);
    }
    return errors;
}
module.exports = { EXTENDED, MODIFIERS, MODIFIER_KEYS, bindingError, chord, colorError, colorChannels, colorValue, conflicts };
