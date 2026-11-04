"use strict";
const { createNativeSelectionLifecycle } = require("./NativeSelectionLifecycle");

const SLOT = "__PBZ_MOD_CONFIG_RUNTIME_V1__";
const BRIDGE_SLOT = "__PBZ_MOD_CONFIG_LOADER_BRIDGE_V1__";
const METHODS = [
    "BP_InitWidget", "applyTabSwitch", "selectFirstSettingDeferred", "SelectWidgetToFocus",
    "ClickCollection", "selectCollection", "handleResetKeyPressed", "backInputInternal",
    "StartResetBindingRecovery", "FinishCurrentWidget"
];
const EXPORTS = ["invalidateResetKeyMemory", "releasePanelHostBinding", "cancelResolutionTransactionForClosedPanel"];

function install(settingModule, UE, puerts, options = {}) {
    const root = options.root || globalThis;
    if (root[SLOT]) throw new Error("MOD_CONFIG_ALREADY_INSTALLED");
    const Panel = settingModule.SettingPanelMixinInterface;
    if (!Panel || !Panel.prototype) throw new Error("SETTING_PANEL_CLASS_MISSING");
    let bridge = root[BRIDGE_SLOT];
    if (bridge && (bridge.Panel !== Panel || bridge.settingModule !== settingModule)) {
        throw new Error("MOD_CONFIG_BRIDGE_OWNER_CHANGED");
    }
    if (!bridge) {
        const records = [];
        for (const name of METHODS) records.push({ owner: Panel.prototype, name, original: Panel.prototype[name] });
        for (const name of EXPORTS) records.push({ owner: settingModule, name, original: settingModule[name] });
        for (const item of records) {
            if (typeof item.original !== "function") throw new Error("NATIVE_LIFECYCLE_MISSING: " + item.name);
        }
        bridge = { Panel, settingModule, records, handlers: null };
        for (const item of records) {
            item.dispatch = function (...args) {
                const method = bridge.handlers ? bridge.handlers.get(item) : item.original;
                return method.apply(this, args);
            };
        }
    }
    const records = bridge.records;
    for (const item of records) {
        if (item.owner[item.name] !== item.original && item.owner[item.name] !== item.dispatch) {
            throw new Error("MOD_CONFIG_WRAPPER_CHANGED: " + item.name);
        }
    }
    // Entry captures the real game methods once. The stable dispatch functions
    // are what a later native mixin caches, allowing a stopped/reloaded Entry to
    // update those cached calls without mixing an existing native class again.
    for (const item of records) item.owner[item.name] = item.original;
    let lifecycle;
    let runtime;
    try {
        lifecycle = createNativeSelectionLifecycle(Panel, root);
        const installEntry = options.installEntry || require("./native/Entry").install;
        runtime = installEntry(Panel, UE, puerts, settingModule, lifecycle, root);
        const finish = Panel.prototype.FinishCurrentWidget;
        Panel.prototype.FinishCurrentWidget = function (...args) {
            try { return finish.apply(this, args); }
            finally { lifecycle.release(this); }
        };
        const release = settingModule.releasePanelHostBinding;
        settingModule.releasePanelHostBinding = function (panel, ...args) {
            try { return release.call(this, panel, ...args); }
            finally { lifecycle.release(panel); }
        };
        bridge.handlers = new Map(records.map(item => [item, item.owner[item.name]]));
        for (const item of records) item.owner[item.name] = item.dispatch;
        root[BRIDGE_SLOT] = bridge;
    } catch (error) {
        lifecycle?.stop();
        for (const item of records) item.owner[item.name] = root[BRIDGE_SLOT] ? item.dispatch : item.original;
        if (runtime && root[SLOT] === runtime) delete root[SLOT];
        throw error;
    }

    let stopped = false;
    return {
        version: runtime.version,
        runtime,
        stop() {
            if (stopped) return;
            for (const item of records) {
                if (item.owner[item.name] !== item.dispatch) throw new Error("MOD_CONFIG_WRAPPER_CHANGED: " + item.name);
            }
            const states = [...runtime.menu.states.values()];
            if (states.some(state => state.covered || state.confirming)) throw new Error("MOD_CONFIG_DIALOG_ACTIVE");
            for (const state of states) {
                if (state.active && state.panel.CurrentCollection === state.collection) {
                    state.tabs.SelectTabByID(state.tabs.GetTabIdAtIndex(0));
                    if (state.panel.CurrentCollection === state.collection) throw new Error("NATIVE_TAB_RETURN_REQUIRED");
                }
                state.dispose();
            }
            if (runtime.framework) runtime.framework.dispose();
            lifecycle.stop();
            bridge.handlers = null;
            if (root[SLOT] === runtime) delete root[SLOT];
            stopped = true;
        }
    };
}

module.exports = { install };
