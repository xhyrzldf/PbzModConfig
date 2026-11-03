"use strict";
const test = require("node:test"), assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm"), path = require("node:path");
const { createDiagnostics, LIMITS } = require("../native/Diagnostics");
test("a million repeated errors retain one counter and no raw error or native object", () => {
    const d = createDiagnostics({ version: "0.3.9", now: () => 1000 }), start = performance.now();
    for (let i = 0; i < 1000000; i++) d.report({ code: "MENU_FAILED", detail: "Error: passing a invalid object", object: { native: true }, path: "C:/Users/Fixture/private/name" });
    console.log("memory diagnostic million-event fixture ms=" + (performance.now() - start).toFixed(1));
    const s = d.snapshot(); assert.equal(s.events.length, 1); assert.equal(s.events[0].count, 1000000);
    assert.equal(s.events[0].cause, "destroyed_object"); assert.ok(!JSON.stringify(s).includes("private"));
    s.events[0].count = -1; assert.equal(d.snapshot().events[0].count, 1000000);
});
test("unique error storm remains at 24 bounded strings, including malformed codes and large details", () => {
    const d = createDiagnostics({ version: "0.3.9", now: () => 1000 });
    for (let i = 0; i < 10000; i++) d.report({ code: "ERROR_" + i, detail: "字".repeat(200) });
    d.report({ code: "C:/Users/Fixture/private/name", detail: "unknown" });
    const s = d.snapshot(); assert.equal(s.events.length, LIMITS.events); assert.equal(s.dropped, 9977);
    assert.equal(s.events.at(-1).code, "OTHER"); assert.ok(Buffer.byteLength(JSON.stringify(s)) < 8192);
});
test("real entry boot and error storm have no diagnostic IO, console or timers with an unavailable filesystem", () => {
    let attempts = 0;
    const forbidden = () => { attempts++; throw new Error("diagnostics must not call this"); };
    const exports = { invalidateResetKeyMemory() {}, releasePanelHostBinding() {}, cancelResolutionTransactionForClosedPanel() {} };
    class Panel {}
    for (const name of ["BP_InitWidget", "applyTabSwitch", "selectFirstSettingDeferred", "SelectWidgetToFocus", "ClickCollection", "selectCollection", "handleResetKeyPressed", "backInputInternal", "StartResetBindingRecovery", "FinishCurrentWidget"]) Panel.prototype[name] = () => {};
    const context = { module: { exports: {} }, setTimeout: forbidden, setInterval: forbidden, console: { warn: forbidden },
        require: name => {
            if (name === "./Diagnostics") return { createDiagnostics };
            if (name === "../src/Metadata") return { version: "0.3.9" };
            if (name === "../provider/Protocol") return { getHub: () => ({}) };
            if (name === "../src/Framework") return { createFramework: () => ({}) };
            if (name === "./NativeMenu") return { createMenu: () => ({ states: new Map(), get: () => undefined, create: () => { throw new Error("passing a invalid object"); } }) };
            throw new Error("unexpected dependency: " + name);
        } };
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../native/Entry.js"), "utf8"), context);
    const root = {}, UE = new Proxy({}, { get: forbidden });
    const r = context.module.exports.install(Panel, UE, {}, exports, {}, root);
    for (let i = 0; i < 10000; i++) new Panel().BP_InitWidget();
    assert.equal(r.diagnostics.snapshot().events.find(e => e.code === "MENU_INSTALL_FAILED").count, 10000);
    assert.equal(context.module.exports.install(Panel, UE, {}, exports, {}, root), r);
    assert.equal(attempts, 0, "catching a forbidden operation is not the same as avoiding it");
});
test("diagnostic module has no ambient IO or timer capabilities", () => {
    let attempts = 0;
    const forbidden = () => { attempts++; throw new Error("unexpected diagnostic side effect"); };
    const context = { module: { exports: {} }, require: forbidden, setTimeout: forbidden, setInterval: forbidden,
        console: { warn: forbidden, log: forbidden }, UE: new Proxy({}, { get: forbidden }) };
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../native/Diagnostics.js"), "utf8"), context);
    const d = context.module.exports.createDiagnostics({ version: "0.3.9" });
    for (let i = 0; i < 100000; i++) d.report({ code: "MENU_FAILED" });
    assert.equal(d.snapshot().events[0].count, 100000);
    assert.equal(attempts, 0);
});
