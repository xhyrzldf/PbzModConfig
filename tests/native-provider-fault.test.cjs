"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const { fixture } = require("./native-input-fixture.cjs");
const { memoryIO } = require("./fixtures.cjs");
const { descriptor } = require("../demo/DemoProvider");
const { createStore } = require("../provider/ConfigStore");
const { createJournal } = require("../provider/Journal");
const { publishOptional } = require("../provider/Protocol");

function faultyMenu() {
    let next = 0, reads = 0, failed = false, store;
    const queued = new Map();
    const timerApi = {setTimeout(fn) { queued.set(++next, fn); return next; }, clearTimeout(id) { queued.delete(id); }, setInterval() { return ++next; }, clearInterval() {}};
    const f = fixture({timerApi, createProvider(root) {
        store = createStore(descriptor("PbzMapTracker"), createJournal(memoryIO(), "PbzMapTracker"));
        const registration = publishOptional({...store, read() {
            reads++;
            if (failed) throw new Error("C:/Users/Fixture/private/player/" + "x".repeat(131072) + reads);
            return store.read();
        }}, root);
        return {dispose() { registration.dispose(); store.dispose(); }};
    }});
    function drain() {
        let turns = 0;
        while (queued.size && turns < 12) {
            const [id, fn] = queued.entries().next().value; queued.delete(id); turns++; fn();
        }
        assert.equal(queued.size, 0, "rendering a provider fault must not schedule itself forever");
        return turns;
    }
    drain();
    return {f, drain, queued, store, fail(value) { failed = value; }, reads() { return reads; }};
}

test("changing provider errors cannot keep the real native menu refresh queue alive", () => {
    const x = faultyMenu();
    try {
        x.fail(true); x.f.state.queueRefresh();
        const before = x.reads(); x.drain();
        assert.ok(x.reads() - before <= 2, "one input must require only bounded reads");
        // Recovery remains driven by the existing provider notification, without polling.
        x.fail(false); x.store.apply({enabled:false}); x.drain();
        assert.equal(x.f.framework.pages()[0].values.enabled, false);
        x.fail(true); x.store.apply({enabled:true}); x.drain();
        assert.equal(x.f.framework.pages()[0].error.operation, "read");
    } finally { x.f.dispose(); }
});

test("provider fault state and reports retain only fixed metadata; rendering emits no new work", () => {
    const x = faultyMenu(); let notifications = 0;
    const off = x.f.framework.subscribe(() => notifications++);
    try {
        x.fail(true);
        for (let i = 0; i < 20; i++) {
            const page = x.f.framework.pages()[0];
            assert.deepEqual(Object.keys(page.error).sort(), ["code", "operation"]);
            assert.deepEqual(page.error, {code:"PROVIDER_FAILED", operation:"read"});
        }
        assert.equal(notifications, 0, "the caller already has the rendered failure state");
        assert.equal(x.queued.size, 0);
        const reports = x.f.reports.filter(e => e.code === "PROVIDER_FAILED");
        assert.equal(reports.length, 1, "changing text is still the same failed operation");
        assert.ok(JSON.stringify(reports).length < 256);
        assert.ok(!JSON.stringify(reports).includes("private"));
    } finally { off(); x.f.dispose(); }
});
