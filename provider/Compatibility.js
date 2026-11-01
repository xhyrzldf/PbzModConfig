"use strict";
const { EXTENDED } = require("./Controls");
// The original V1 hub is frozen and can be created by any older provider first.
// Negotiate on each descriptor, never replace or mutate that shared hub.
function compatibleDescriptor(provider) {
    if (!provider?.entries?.some(e => EXTENDED.has(e.type))) return provider;
    const omitted = new Set(provider.entries.filter(e => EXTENDED.has(e.type)).map(e => e.key));
    let changed;
    do {
        changed = false;
        for (const e of provider.entries) if (!omitted.has(e.key) && [e.enabledWhen, e.visibleWhen].some(r => r && omitted.has(r.key))) {
            omitted.add(e.key); changed = true;
        }
    } while (changed);
    const entries = provider.entries.filter(e => !omitted.has(e.key));
    const keys = new Set(entries.filter(e => ["toggle", "number", "choice"].includes(e.type)).map(e => e.key));
    const project = snapshot => ({ ...snapshot, values: Object.fromEntries(Object.entries(snapshot.values || {}).filter(([key]) => keys.has(key))) });
    const legacy = {
        ...provider, entries,
        getExtendedDescriptor(version) { return version === 1 ? provider : null; },
        read() { return project(provider.read()); },
        apply(patch, context) {
            if (!patch || typeof patch !== "object" || Array.isArray(patch) || Object.keys(patch).some(k => !keys.has(k)))
                return { ...project(provider.read()), ok: false, error: "UNKNOWN_KEY" };
            return project(provider.apply(patch, context));
        },
        subscribe(listener) { return provider.subscribe(event => listener(project(event))); },
        reset(groupId, context) {
            if (groupId !== undefined && !provider.groups.some(g => g.id === groupId)) return { ...project(provider.read()), ok: false, error: "UNKNOWN_GROUP" };
            const patch = Object.fromEntries(entries.filter(e => keys.has(e.key) && (groupId === undefined || e.group === groupId)).map(e => [e.key, e.defaultValue]));
            return project(provider.apply(patch, { ...context, origin: context?.origin || "reset" }));
        },
        flush() { return project(provider.flush()); },
        invokeAction(key, context) { return project(provider.invokeAction(key, context)); }
    };
    // Hidden extended values remain in the owning store and are never rewritten
    // from the projection. A plain header gives old menus an upgrade hint.
    let key = "modconfig.extensions";
    while (provider.entries.some(e => e.key === key)) key += "_";
    legacy.entries = Object.freeze([...entries, Object.freeze({ key, type: "header", label: {
        en: "Additional controls require ModConfig 0.3.0 or newer", zhHans: "更多设置需要 ModConfig 0.3.0 或更新版本"
    } })]);
    return Object.freeze(legacy);
}
module.exports = { compatibleDescriptor };
