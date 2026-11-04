"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { createNativeSelectionLifecycle } = require("../loader/NativeSelectionLifecycle");

// A controlled private-state fixture keeps these timer tests independent of game files.
function fixture() {
    let next = 0;
    const queue = new Map(), removed = [], states = new WeakMap();
    const root = {
        setTimeout(callback, delay, ...args) {
            const id = ++next;
            queue.set(id, { callback, delay, args });
            return id;
        },
        clearTimeout(id) { removed.push(id); queue.delete(id); }
    };
    function state(panel) {
        if (!states.has(panel)) states.set(panel, { pendingSelect: null,
            selectWidgetFocusTimer: null, settingHostAcceptsFocus: true });
        return states.get(panel);
    }
    class Panel {
        selectFirstSettingDeferred(focus) {
            const current = state(this);
            if (current.pendingSelect) root.clearTimeout(current.pendingSelect.timer);
            const intent = { collection: this.CurrentCollection, focus, attempts: 0, timer: null };
            current.pendingSelect = intent;
            const poll = () => {
                if (current.pendingSelect !== intent || this.ListView_Settings.ListItems.Num()) return;
                intent.attempts++;
                intent.timer = root.setTimeout(poll, 16);
            };
            intent.timer = root.setTimeout(poll, 0);
        }
        SelectWidgetToFocus() {
            const current = state(this);
            root.clearTimeout(current.selectWidgetFocusTimer);
            current.selectWidgetFocusTimer = root.setTimeout(() => { current.selectWidgetFocusTimer = null; }, 10);
        }
    }
    const originalPending = Panel.prototype.selectFirstSettingDeferred;
    const originalFocus = Panel.prototype.SelectWidgetToFocus;
    const lifecycle = createNativeSelectionLifecycle(Panel, root);
    function panel() {
        const value = new Panel();
        value.CurrentCollection = {};
        value.ListView_Settings = { ListItems: { Num: () => 0 } };
        value.WidgetSwitcher_65 = { GetActiveWidgetIndex: () => 1 };
        return value;
    }
    function fire(id) {
        const item = queue.get(id);
        assert.ok(item, "requested timer is still queued");
        queue.delete(id);
        item.callback(...item.args);
    }
    return { root, queue, removed, Panel, panel, state, fire, lifecycle, originalPending, originalFocus };
}


test("the pending intent is replaced and its real timer is canceled", () => {
    const f = fixture(), panel = f.panel(), collection = panel.CurrentCollection;
    panel.selectFirstSettingDeferred(true);
    const oldIntent = f.state(panel).pendingSelect;
    const oldTimer = oldIntent.timer;
    assert.ok(f.queue.has(oldTimer));
    f.lifecycle.clearPendingSelect(panel);
    assert.notEqual(f.state(panel).pendingSelect, oldIntent);
    assert.equal(f.state(panel).pendingSelect.collection, undefined);
    assert.equal(panel.CurrentCollection, collection);
    assert.equal(f.queue.size, 0);
    assert.ok(f.removed.includes(oldTimer));
    panel.selectFirstSettingDeferred(false);
    assert.equal(f.state(panel).pendingSelect.collection, collection);
    assert.equal(f.queue.size, 1, "returning to a native page replaces the inert intent normally");
    f.lifecycle.stop();
});

test("recursive native polling stays tracked while two panels remain isolated", () => {
    const f = fixture(), first = f.panel(), second = f.panel();
    first.selectFirstSettingDeferred(true);
    second.selectFirstSettingDeferred(true);
    const firstTimer = f.state(first).pendingSelect.timer;
    const secondTimer = f.state(second).pendingSelect.timer;
    f.fire(firstTimer);
    const repeated = f.state(first).pendingSelect.timer;
    assert.notEqual(repeated, firstTimer);
    f.lifecycle.clearPendingSelect(first);
    assert.ok(!f.queue.has(repeated));
    assert.ok(f.queue.has(secondTimer));
    f.fire(secondTimer);
    assert.equal(f.state(second).pendingSelect.attempts, 1);
    f.lifecycle.stop();
});

test("already queued callbacks are revoked even when a backend dispatches after cancellation", () => {
    const f = fixture(), panel = f.panel();
    panel.selectFirstSettingDeferred(true);
    const late = f.queue.get(f.state(panel).pendingSelect.timer).callback;
    f.lifecycle.clearPendingSelect(panel);
    late();
    assert.equal(f.queue.size, 0);
    assert.equal(f.state(panel).pendingSelect.attempts, 0);
    f.lifecycle.stop();
});

test("focus cancellation uses the exact native handle without deactivating the host", () => {
    const f = fixture(), first = f.panel(), second = f.panel();
    first.SelectWidgetToFocus();
    second.SelectWidgetToFocus();
    const firstTimer = f.state(first).selectWidgetFocusTimer;
    const secondTimer = f.state(second).selectWidgetFocusTimer;
    f.lifecycle.cancelSelectWidgetFocusTimer(first);
    assert.ok(!f.queue.has(firstTimer));
    assert.ok(f.queue.has(secondTimer));
    assert.equal(f.state(first).settingHostAcceptsFocus, true);
    f.fire(secondTimer);
    assert.equal(f.state(second).selectWidgetFocusTimer, null);
    f.lifecycle.stop();
});

test("unrelated callbacks created while a poll runs keep their own lifecycle", () => {
    const f = fixture(), panel = f.panel();
    let unrelated;
    panel.ListView_Settings.ListItems.Num = () => {
        unrelated = f.root.setTimeout(() => {}, 120);
        return 0;
    };
    panel.selectFirstSettingDeferred(false);
    f.fire(f.state(panel).pendingSelect.timer);
    f.lifecycle.clearPendingSelect(panel);
    assert.ok(f.queue.has(unrelated));
    assert.equal(f.queue.size, 1);
    f.root.clearTimeout(unrelated);
    f.lifecycle.stop();
});

test("synchronous failure restores CurrentCollection and the global scheduler", () => {
    const f = fixture(), panel = f.panel(), collection = panel.CurrentCollection;
    const scheduler = f.root.setTimeout;
    Object.defineProperty(panel, "CurrentCollection", {
        configurable: true,
        get() { return collection; },
        set(value) { if (value === undefined) throw new Error("field setter failed"); }
    });
    assert.throws(() => f.lifecycle.clearPendingSelect(panel), /field setter failed/);
    assert.equal(panel.CurrentCollection, collection);
    assert.equal(f.root.setTimeout, scheduler);
    f.lifecycle.stop();
    assert.equal(f.Panel.prototype.selectFirstSettingDeferred, f.originalPending);
    assert.equal(f.Panel.prototype.SelectWidgetToFocus, f.originalFocus);
});
