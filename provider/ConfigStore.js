"use strict";
const S = require("./Schema");
function createStore(descriptor, storage, options = {}) {
    const sink = options.report || (event => console.warn("[PbzConfig] " + JSON.stringify(event)));
    const report = event => { try { sink({ modId: descriptor.modId, ...event }); } catch (_) {} };
    const schema = S.compile(descriptor, report), listeners = new Set();
    const schedule = options.schedule || setTimeout, cancel = options.cancel || clearTimeout;
    const delay = options.delay ?? 250, maxDelay = options.maxDelay ?? 1500;
    let values = { ...schema.defaults }, revision = 0, dirty = false, disposed = false, blocked = false;
    let timer = null, deadline = null, persistence = { state: "saved" };
    const previews = new Set();
    function stopPreviews() {
        for (const stop of Array.from(previews)) stop();
    }
    const snapshot = () => S.deepFreeze({ revision, values: { ...values }, persistence: { ...persistence } });
    function emit(origin) {
        const event = { ...snapshot(), origin };
        for (const listener of Array.from(listeners)) {
            try { listener(event); } catch (e) { report({ code: "SUBSCRIBER_FAILED", detail: String(e) }); }
        }
    }
    function clearTimers() {
        if (timer !== null) cancel(timer);
        if (deadline !== null) cancel(deadline);
        timer = deadline = null;
    }
    function result(ok, error, fields) { return { ok, ...snapshot(), ...(error ? { error, fields } : {}) }; }
    function flush() {
        clearTimers();
        if (blocked) return result(false, "RECOVERY_REQUIRED");
        if (!dirty) return result(true);
        try {
            storage.save({ schemaVersion: descriptor.schemaVersion, revision, values: { ...values } });
            dirty = false;
            persistence = { state: "saved" };
            emit("persistence");
            return result(true);
        } catch (e) {
            persistence = { state: "failed", error: String(e) };
            report({ code: "SAVE_FAILED", detail: String(e) });
            emit("persistence");
            return result(false, "SAVE_FAILED");
        }
    }
    function queueSave() {
        dirty = true;
        if (blocked) return;
        persistence = { state: "pending" };
        if (timer !== null) cancel(timer);
        timer = schedule(flush, delay);
        if (deadline === null) deadline = schedule(flush, maxDelay);
    }
    try {
        const loaded = storage.load();
        loaded.errors?.forEach(report);
        blocked = !!loaded.blocked;
        if (loaded.record) {
            let record = loaded.record;
            if (record.schemaVersion !== descriptor.schemaVersion) {
                if (!options.migrate || record.schemaVersion > descriptor.schemaVersion) throw new Error("MIGRATION_REQUIRED");
                record = options.migrate(S.copy(record), descriptor.schemaVersion);
                if (!record || record.schemaVersion !== descriptor.schemaVersion) throw new Error("INVALID_MIGRATION");
            }
            const errors = S.validatePatch(schema, record.values, schema.defaults);
            if (Object.keys(errors).length) throw new Error("INVALID_STORED_VALUES: " + JSON.stringify(errors));
            if (!Number.isSafeInteger(record.revision) || record.revision < 0) throw new Error("INVALID_REVISION");
            values = { ...values, ...record.values };
            revision = record.revision;
            const changed = loaded.record.schemaVersion !== descriptor.schemaVersion || Object.keys(values).length !== Object.keys(record.values).length;
            if (changed) {
                if (revision >= Number.MAX_SAFE_INTEGER) throw new Error("REVISION_OVERFLOW");
                revision++;
                queueSave();
            }
        } else if (!blocked) queueSave();
        if (blocked) persistence = { state: "failed", error: "RECOVERY_REQUIRED" };
    } catch (e) {
        clearTimers(); blocked = true;
        persistence = { state: "failed", error: String(e) };
        report({ code: "LOAD_FAILED", detail: String(e) });
    }
    function apply(patch, context = {}) {
        if (disposed) return result(false, "PROVIDER_DISPOSED");
        if (context.baseRevision !== undefined && context.baseRevision !== revision) return result(false, "REVISION_CONFLICT");
        const errors = S.validatePatch(schema, patch, values);
        if (Object.keys(errors).length) return result(false, "VALIDATION_FAILED", errors);
        const changed = Object.entries(patch).some(([k, v]) => values[k] !== v);
        if (!changed) return result(true);
        if (revision >= Number.MAX_SAFE_INTEGER) return result(false, "REVISION_OVERFLOW");
        stopPreviews();
        // An owner's stop callback may synchronously change or dispose its store.
        if (disposed) return result(false, "PROVIDER_DISPOSED");
        if (context.baseRevision !== undefined && context.baseRevision !== revision) return result(false, "REVISION_CONFLICT");
        const afterStop = S.validatePatch(schema, patch, values);
        if (Object.keys(afterStop).length) return result(false, "VALIDATION_FAILED", afterStop);
        values = { ...values, ...patch };
        revision++;
        queueSave();
        emit(context.origin || "business");
        return result(true);
    }
    const provider = {
        ...descriptor,
        displayName: S.deepFreeze(S.copy(descriptor.displayName)),
        groups: Object.freeze(Array.from(schema.groups.values())),
        entries: Object.freeze(Array.from(schema.entries.values())),
        read: snapshot,
        apply,
        subscribe(listener) {
            if (disposed) throw new Error("PROVIDER_DISPOSED");
            if (typeof listener !== "function") throw new Error("INVALID_LISTENER");
            listeners.add(listener);
            return () => listeners.delete(listener);
        },
        reset(groupId, context = {}) {
            if (groupId !== undefined && !schema.groups.has(groupId)) return result(false, "UNKNOWN_GROUP");
            const patch = {};
            for (const [key, entry] of schema.values) if (groupId === undefined || entry.group === groupId) patch[key] = entry.defaultValue;
            return apply(patch, { ...context, origin: context.origin || "reset" });
        },
        flush,
        previewSound(key, context = {}) {
            stopPreviews();
            if (disposed) return { ok: false, error: "PROVIDER_DISPOSED" };
            if (context.baseRevision !== undefined && context.baseRevision !== revision) return { ok: false, error: "REVISION_CONFLICT" };
            const entry = schema.entries.get(key);
            if (!entry || entry.type !== "sound" || typeof options.sounds?.[key] !== "function") return { ok: false, error: "PREVIEW_UNAVAILABLE" };
            if (!S.enabled(entry, values) || !S.visible(entry, values)) return { ok: false, error: "DISABLED" };
            try {
                const startedRevision = revision;
                const stop = options.sounds[key](values[key]);
                if (typeof stop !== "function") throw new Error("PREVIEW_STOP_REQUIRED");
                let live = true;
                const finish = () => {
                    if (!live) return;
                    live = false; previews.delete(finish);
                    try { stop(); } catch (e) { report({ code: "PREVIEW_STOP_FAILED", detail: String(e) }); }
                };
                previews.add(finish);
                if (disposed || revision !== startedRevision) { finish(); return { ok: false, error: "PREVIEW_CHANGED" }; }
                return { ok: true, stop: finish };
            } catch (e) { report({ code: "PREVIEW_FAILED", detail: String(e) }); return { ok: false, error: "PREVIEW_FAILED" }; }
        },
        invokeAction(actionId, context = {}) {
            if (disposed) return result(false, "PROVIDER_DISPOSED");
            if (context.baseRevision !== undefined && context.baseRevision !== revision) return result(false, "REVISION_CONFLICT");
            const entry = schema.entries.get(actionId);
            if (!entry || entry.type !== "action" || typeof options.actions?.[actionId] !== "function") return result(false, "UNKNOWN_ACTION");
            if (!S.enabled(entry, values) || !S.visible(entry, values)) return result(false, "DISABLED");
            try {
                const actionResult = options.actions[actionId]({ apply, read: snapshot, flush });
                if (!actionResult || typeof actionResult.ok !== "boolean" || typeof actionResult.then === "function") throw new Error("INVALID_ACTION_RESULT");
                return actionResult.ok ? result(true) : result(false, actionResult.error || "ACTION_FAILED");
            } catch (e) { report({ code: "ACTION_FAILED", detail: String(e) }); return result(false, "ACTION_FAILED"); }
        },
        dispose() {
            if (disposed) return result(true);
            stopPreviews();
            const outcome = flush();
            if (!outcome.ok) return outcome; // caller can retry; do not discard dirty ownership.
            disposed = true;
            listeners.clear();
            return outcome;
        }
    };
    return Object.freeze(provider);
}
module.exports = { createStore };
