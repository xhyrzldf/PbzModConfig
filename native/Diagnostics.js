"use strict";
// Memory only. No timers, console, filesystem or network calls: the verified
// game filesystem binding is synchronous and can stall gameplay.
const LIMITS = Object.freeze({ events: 24, codeLength: 64, count: 2147483647 });
function createDiagnostics({ version, now = Date.now }) {
    const events = new Map(), startedAt = now();
    let dropped = 0;
    function report(event) {
        const value = event?.code;
        const code = typeof value === "string" && value.length <= LIMITS.codeLength && /^[A-Z][A-Z0-9_]*$/.test(value) ? value : "OTHER";
        const time = Math.max(startedAt, now());
        let item = events.get(code);
        if (!item) {
            if (events.size === LIMITS.events) { events.delete(events.keys().next().value); dropped = Math.min(LIMITS.count, dropped + 1); }
            item = { code, count: 0, firstAt: time, lastAt: time, cause: "none" }; events.set(code, item);
        }
        item.count = Math.min(LIMITS.count, item.count + 1); item.lastAt = Math.max(item.lastAt, time);
        const detail = typeof event?.detail === "string" ? event.detail.slice(0, 160) : undefined;
        item.cause = detail === undefined ? "none" :
            detail.includes("passing a invalid object") || detail.includes("access a invalid object") ? "destroyed_object" :
            detail.startsWith("TypeError:") ? "type_error" : detail.startsWith("ReferenceError:") ? "reference_error" : "other";
    }
    // Explicit bounded snapshot for local debugging; production never serializes it.
    function snapshot() { return { version, startedAt, dropped, events: [...events.values()].map(e => ({ ...e })) }; }
    return { report, snapshot };
}
module.exports = { createDiagnostics, LIMITS };
