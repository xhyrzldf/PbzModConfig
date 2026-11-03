"use strict";
const { getHub } = require("../provider/Protocol");
const { createFramework } = require("../src/Framework");
const { createMenu } = require("./NativeMenu");
const { version } = require("../src/Metadata");
const { createDiagnostics } = require("./Diagnostics");
const SLOT = "__PBZ_MOD_CONFIG_RUNTIME_V1__";
function install(Panel, UE, puerts, exports, nativeLifecycle, root = globalThis) {
    if (root[SLOT]) return root[SLOT];
    const runtime = { version, route: "native-row-adapter", menu: null };
    const diagnostics = createDiagnostics({ version });
    runtime.diagnostics = diagnostics;
    const report = diagnostics.report;
    const hub = getHub(root, report), framework = createFramework(hub, { report });
    runtime.framework = framework;
    const menu = createMenu(UE, puerts, framework, report); runtime.menu = menu;
    const failedPanels = new WeakSet();
    const current = panel => {
        const state = menu.get(panel);
        return state ? protect(panel, state, () => panel.CurrentCollection === state.collection ? state : null) : null;
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
    // Only guard our work: native handlers still run in their original order,
    // and their own exceptions are not swallowed or retried.
    const protect = (panel, state, callback, code = "MENU_FAILED") => {
        try { return callback(); } catch (error) {
            failedPanels.add(panel);
            const failedState = state || menu.get(panel);
            if (failedState?.fail) return failedState.fail(error, code);
            let detail;
            try {
                const value = typeof error === "string" ? error : error?.message;
                if (typeof value === "string") detail = value.slice(0, 160);
            } catch (_) {} // An invalid native wrapper may itself reject access.
            report({ code, detail });
            try { failedState?.dispose(); }
            catch (_) { report({ code: "MENU_RETIRE_FAILED" }); }
        }
    };
    wrap("BP_InitWidget", function (original, args) {
        const result = original.apply(this, args);
        if (failedPanels.has(this) || menu.isFailed?.(this)) return result;
        protect(this, null, () => {
            const state = menu.get(this) || menu.create(this);
            state.bindHost(); state.styleTab(); state.resume();
        }, "MENU_INSTALL_FAILED");
        return result;
    });
    wrap("applyTabSwitch", function (original, args) {
        const state = menu.get(this);
        if (state) protect(this, state, () => { quiesce(this); state.hide(); });
        const result = original.apply(this, args); // Keep the game's pending-video confirmation flow.
        if (state && !state.disposed && args[1] === state.collection) protect(this, state, () => { quiesce(this); state.show(); });
        return result;
    });
    wrap("selectFirstSettingDeferred", function (original, args) {
        const state = current(this);
        if (!state) return original.apply(this, args);
        protect(this, state, () => {
            quiesce(this);
            state.pendingFocus = state.selected || [...state.byId.keys()].find(id => state.models.get(state.byId.get(id)).type !== "header");
            state.focusReady();
        });
    });
    wrap("SelectWidgetToFocus", function (original, args) {
        const state = current(this);
        if (!state) return original.apply(this, args);
        protect(this, state, () => { quiesce(this); state.pendingFocus = state.selected || state.pendingFocus; state.focusReady(); });
    });
    for (const name of ["ClickCollection", "selectCollection"]) wrap(name, function (original, args) {
        const state = current(this);
        if (!state || args[0] !== state.collection) return original.apply(this, args);
        protect(this, state, () => state.show());
    });
    wrap("handleResetKeyPressed", function (original, args) {
        const state = current(this);
        if (!state) return original.apply(this, args);
        protect(this, state, () => {
            const m = state.models.get(state.byId.get(state.selected));
            if (m?.page) state.action(m.page.handle.modId + "/@reset");
        });
    });
    wrap("backInputInternal", function (original, args) {
        const state = current(this); if (state) protect(this, state, () => { quiesce(this); state.pendingFocus = null; state.flush(); });
        return original.apply(this, args);
    });
    wrap("StartResetBindingRecovery", function (original, args) {
        const result = original.apply(this, args);
        const state = current(this); if (state) protect(this, state, () => state.resume());
        return result;
    });
    wrap("FinishCurrentWidget", function (original, args) {
        const state = menu.get(this);
        if (state) protect(this, state, () => state.dispose());
        if (state) report({ code: "MENU_CLOSED" });
        return original.apply(this, args);
    });
    // The title-screen wrapper imports these exports. No replacement of its script is needed.
    for (const [name, operation] of [["invalidateResetKeyMemory", "cover"], ["releasePanelHostBinding", "dispose"], ["cancelResolutionTransactionForClosedPanel", "dispose"]]) {
        const original = exports[name];
        if (typeof original !== "function") throw new Error("HOST_EXPORT_MISSING: " + name);
        exports[name] = function (panel, ...args) {
            const state = menu.get(panel);
            if (state) protect(panel, state, () => state[operation]());
            return original(panel, ...args);
        };
    }
    runtime.isInputCaptured = () => [...menu.states.values()].some(state => !state.disposed && (state.active || state.covered));
    root[SLOT] = runtime;
    report({ code: "FRAMEWORK_LOADED", version: runtime.version });
    return runtime;
}
module.exports = { install };
