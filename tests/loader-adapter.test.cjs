"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { install } = require("../loader/LoaderAdapter");

function fixture() {
    class Panel {}
    const calls = [];
    const methods = ["BP_InitWidget", "applyTabSwitch", "selectFirstSettingDeferred", "SelectWidgetToFocus", "ClickCollection", "selectCollection", "handleResetKeyPressed", "backInputInternal", "StartResetBindingRecovery", "FinishCurrentWidget"];
    for (const name of methods) Panel.prototype[name] = function () { calls.push("native:" + name); return name; };
    const settingModule = { SettingPanelMixinInterface: Panel };
    for (const name of ["invalidateResetKeyMemory", "releasePanelHostBinding", "cancelResolutionTransactionForClosedPanel"]) {
        settingModule[name] = () => name;
    }
    const root = { setTimeout() { return 1; }, clearTimeout() {} };
    let version = 0, disposed = 0;
    function installEntry(CurrentPanel, UE, puerts, exports, lifecycle, currentRoot) {
        const revision = ++version;
        const original = CurrentPanel.prototype.BP_InitWidget;
        CurrentPanel.prototype.BP_InitWidget = function (...args) {
            calls.push("entry:" + revision);
            return original.apply(this, args);
        };
        const runtime = { version: revision, menu: { states: new Map() }, framework: { dispose() { disposed++; } } };
        currentRoot.__PBZ_MOD_CONFIG_RUNTIME_V1__ = runtime;
        return runtime;
    }
    return { Panel, settingModule, root, installEntry, calls, disposed: () => disposed };
}

test("a native-cached dispatch observes stop and a fresh Entry without remixing", () => {
    const f = fixture(), panel = new f.Panel();
    const first = install(f.settingModule, {}, {}, f);
    const nativeCached = f.Panel.prototype.BP_InitWidget;
    nativeCached.call(panel);
    first.stop();
    nativeCached.call(panel);
    const second = install(f.settingModule, {}, {}, f);
    assert.equal(f.Panel.prototype.BP_InitWidget, nativeCached);
    nativeCached.call(panel);
    assert.deepEqual(f.calls, ["entry:1", "native:BP_InitWidget", "native:BP_InitWidget", "entry:2", "native:BP_InitWidget"]);
    second.stop();
    assert.equal(f.disposed(), 2);
});

test("install failure restores original methods and preserves the original exception", () => {
    const f = fixture(), original = f.Panel.prototype.BP_InitWidget, error = Error("framework failure");
    assert.throws(() => install(f.settingModule, {}, {}, { ...f, installEntry() { throw error; } }), value => value === error);
    assert.equal(f.Panel.prototype.BP_InitWidget, original);
    assert.equal(f.root.__PBZ_MOD_CONFIG_RUNTIME_V1__, undefined);
});

test("another mod changing an owned wrapper is reported before cleanup", () => {
    const f = fixture(), adapter = install(f.settingModule, {}, {}, f);
    const dispatch = f.Panel.prototype.BP_InitWidget;
    f.Panel.prototype.BP_InitWidget = () => {};
    assert.throws(() => adapter.stop(), /MOD_CONFIG_WRAPPER_CHANGED/);
    assert.equal(f.disposed(), 0);
    f.Panel.prototype.BP_InitWidget = dispatch;
    adapter.stop();
});

test("a covered panel blocks reload before any menu or framework is disposed", () => {
    const f = fixture(), adapter = install(f.settingModule, {}, {}, f);
    adapter.runtime.menu.states.set({}, { covered: true, dispose() { assert.fail("must wait for the dialog"); } });
    assert.throws(() => adapter.stop(), /MOD_CONFIG_DIALOG_ACTIVE/);
    assert.equal(f.disposed(), 0);
    adapter.runtime.menu.states.clear();
    adapter.stop();
});
