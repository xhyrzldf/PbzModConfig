"use strict";
const { getHub } = require("../provider/Protocol");
const { createFramework } = require("../src/Framework");
const { resolveUserRoot } = require("../provider/StorageRoot");
const { createMenu } = require("./NativeMenu");
const { version } = require("../src/Metadata");
const SLOT = "__PBZ_MOD_CONFIG_RUNTIME_V1__";
function install(Panel, UE, puerts, exports, nativeLifecycle, root = globalThis) {
    if (root[SLOT]) return root[SLOT];
    const runtime = { version, route: "native-row-adapter", events: [], storageRoot: null, menu: null };
    let diagnosticTimer = null;
    const report = event => {
        const entry = { time: Date.now(), ...event };
        runtime.events.push(entry); if (runtime.events.length > 80) runtime.events.shift();
        console.warn("[PbzModConfig] " + JSON.stringify(entry));
        if (runtime.storageRoot && diagnosticTimer === null) diagnosticTimer = setTimeout(() => {
            diagnosticTimer = null;
            try {
                const payload = JSON.stringify({ version: runtime.version, route: runtime.route, events: runtime.events });
                if (!UE.EasyCsv.SaveStringToFile(payload, runtime.storageRoot + "/PbzModConfig/diagnostics")) console.warn("[PbzModConfig] DIAGNOSTIC_WRITE_FAILED");
            } catch (e) { console.warn("[PbzModConfig] DIAGNOSTIC_WRITE_FAILED " + String(e)); }
        }, 200);
    };
    const hub = getHub(root, report), framework = createFramework(hub, { report });
    runtime.framework = framework;
    try {
        runtime.storageRoot = resolveUserRoot(UE);
    } catch (e) {
        report({ code: "DIAGNOSTIC_STORAGE_UNAVAILABLE", detail: String(e) });
    }
    const menu = createMenu(UE, puerts, framework, report); runtime.menu = menu;
    const failedPanels = new WeakSet();
    const current = panel => {
        const state = menu.get(panel);
        return state && panel.CurrentCollection === state.collection ? state : null;
    };
    const quiesce = panel => {
        nativeLifecycle.clearPendingSelect(panel);
        nativeLifecycle.cancelSelectWidgetFocusTimer(panel);
    };
    const wrap = (name, handler) => {
        const original = Panel.prototype[name];
        if (typeof original !== "function") throw new Error("NATIVE_LIFECYCLE_MISSING: " + name);
        Panel.prototype[name] = function (...args) { return handler.call(this, original, args); };
    };
    wrap("BP_InitWidget", function (original, args) {
        const result = original.apply(this, args);
        if (failedPanels.has(this)) return result;
        try {
            const state = menu.get(this) || menu.create(this);
            state.bindHost(); state.styleTab(); state.resume();
        } catch (e) { failedPanels.add(this); report({ code: "MENU_INSTALL_FAILED", detail: String(e) }); }
        return result;
    });
    wrap("applyTabSwitch", function (original, args) {
        const state = menu.get(this);
        if (state) { quiesce(this); state.hide(); }
        const result = original.apply(this, args); // Keep the game's pending-video confirmation flow.
        if (state && args[1] === state.collection) menu.protect(state, () => { quiesce(this); state.show(); });
        return result;
    });
    wrap("selectFirstSettingDeferred", function (original, args) {
        const state = current(this);
        if (!state) return original.apply(this, args);
        quiesce(this);
        state.pendingFocus = state.selected || [...state.byId.keys()].find(id => state.models.get(state.byId.get(id)).type !== "header");
        state.focusReady();
    });
    wrap("SelectWidgetToFocus", function (original, args) {
        const state = current(this);
        if (!state) return original.apply(this, args);
        quiesce(this); state.pendingFocus = state.selected || state.pendingFocus; state.focusReady();
    });
    for (const name of ["ClickCollection", "selectCollection"]) wrap(name, function (original, args) {
        const state = current(this);
        if (!state || args[0] !== state.collection) return original.apply(this, args);
        state.show();
    });
    wrap("handleResetKeyPressed", function (original, args) {
        const state = current(this);
        if (!state) return original.apply(this, args);
        const m = state.models.get(state.byId.get(state.selected));
        if (m?.page) state.action(m.page.handle.modId + "/@reset");
    });
    wrap("backInputInternal", function (original, args) {
        const state = current(this); if (state) { quiesce(this); state.pendingFocus = null; state.flush(); }
        return original.apply(this, args);
    });
    wrap("StartResetBindingRecovery", function (original, args) {
        const result = original.apply(this, args);
        const state = current(this); if (state) menu.protect(state, () => state.resume());
        return result;
    });
    wrap("FinishCurrentWidget", function (original, args) {
        const state = menu.get(this);
        if (state) menu.protect(state, () => state.dispose());
        return original.apply(this, args);
    });
    // The title-screen wrapper imports these exports. No replacement of its script is needed.
    for (const [name, operation] of [["invalidateResetKeyMemory", "cover"], ["releasePanelHostBinding", "dispose"], ["cancelResolutionTransactionForClosedPanel", "dispose"]]) {
        const original = exports[name];
        if (typeof original !== "function") throw new Error("HOST_EXPORT_MISSING: " + name);
        exports[name] = function (panel, ...args) {
            const state = menu.get(panel);
            if (state) menu.protect(state, () => state[operation]());
            return original(panel, ...args);
        };
    }
    runtime.isInputCaptured = () => [...menu.states.values()].some(state => !state.disposed && (state.active || state.covered));
    root[SLOT] = runtime;
    report({ code: "FRAMEWORK_LOADED", version: runtime.version });
    return runtime;
}
module.exports = { install };
