"use strict";
const S = require("../provider/Schema");
const L = require("./Localization");
function createFramework(hub, options = {}) {
    const records = new Map(), listeners = new Set();
    let disposed = false, locale = "zhHans", playback = null, previewGeneration = 0, visual = null, visualGeneration = 0;
    const report = event => { try { (options.report || (e => console.warn("[PbzModConfig] " + JSON.stringify(e))))(event); } catch (_) {} };
    function stopPreview() {
        const generation = ++previewGeneration;
        const old = playback; playback = null;
        if (old) try { old.stop(); } catch (e) { report({ code: "PREVIEW_STOP_FAILED", detail: String(e) }); }
        return generation;
    }
    function stopVisual() {
        const generation=++visualGeneration,old=visual;visual=null;
        if(old)try{old.controller.dispose();}catch(e){report({code:"VISUAL_PREVIEW_STOP_FAILED",detail:String(e)});}
        return generation;
    }
    function emit(event) {
        for (const listener of Array.from(listeners)) try { listener(event); } catch (e) { report({ code: "VIEW_FAILED", detail: String(e) }); }
    }
    function fault(record, operation, error) {
        if (playback?.record === record) stopPreview();
        if (visual?.record === record) stopVisual();
        const next = { code: "PROVIDER_FAILED", operation, detail: String(error) };
        if (JSON.stringify(record.error) === JSON.stringify(next)) return;
        record.error = next;
        report({ modId: record.modId, ...record.error });
        emit({ type: "error", modId: record.modId });
    }
    function read(record) {
        if (record.attachmentError) return null;
        try {
            const value = record.descriptor.read();
            if (!value || !Number.isSafeInteger(value.revision) || value.revision < 0 ||
                !["saved", "pending", "failed"].includes(value.persistence?.state) ||
                Object.keys(S.validatePatch(record.schema, value.values, value.values)).length ||
                Array.from(record.schema.values.keys()).some(k => !S.own(value.values, k))) throw new Error("INVALID_SNAPSHOT");
            if (record.revision !== undefined && value.revision < record.revision) throw new Error("REVISION_REGRESSED");
            record.revision = value.revision;
            if (playback?.record === record) {
                const e = record.schema.entries.get(playback.key);
                if (!e || value.values[e.key] !== playback.value || !S.enabled(e, value.values) || !S.visible(e, value.values)) stopPreview();
            }
            record.error = null;
            return S.copy(value);
        } catch (e) { fault(record, "read", e); return null; }
    }
    function release(record) {
        if (playback?.record === record) stopPreview();
        if (visual?.record === record) stopVisual();
        record.active = false;
        try { record.unsubscribe?.(); } catch (e) { report({ code: "UNSUBSCRIBE_FAILED", modId: record.modId, detail: String(e) }); }
    }
    function sync() {
        if (disposed) return;
        const snapshot = hub.snapshotProviders(), present = new Set(snapshot.map(r => r.modId));
        for (const [modId, record] of records) if (!present.has(modId)) { release(record); records.delete(modId); }
        for (const item of snapshot) {
            // A subscription may synchronously publish a replacement while this
            // older snapshot is still being enumerated.
            if (hub.providers.get(item.modId)?.ownerToken !== item.ownerToken) continue;
            const old = records.get(item.modId);
            if (old?.ownerToken === item.ownerToken) continue;
            if (old) release(old);
            const record = { ...item, active: true, schema: null, error: null };
            records.set(item.modId, record);
            try {
                if (typeof record.descriptor.getExtendedDescriptor === "function") {
                    const extended = record.descriptor.getExtendedDescriptor(1);
                    if (extended) record.descriptor = extended;
                }
                record.schema = S.compile(record.descriptor, report);
                // Subscribe first, then read. Providers may synchronously notify on subscribe.
                record.unsubscribe = record.descriptor.subscribe(() => {
                    if (disposed || !record.active || records.get(item.modId) !== record) return;
                    if (read(record)) emit({ type: "values", modId: item.modId });
                });
                if (typeof record.unsubscribe !== "function") throw new Error("INVALID_UNSUBSCRIBE");
                if (!record.active) { release(record); continue; }
                read(record);
            } catch (e) {
                record.attachmentError = true;
                fault(record, "attach", e);
            }
        }
        emit({ type: "providers" });
    }
    const unsubscribeHub = hub.subscribeProviders(sync);
    sync();
    function lookup(handle) {
        const record = records.get(handle?.modId);
        return record && record.active && record.ownerToken === handle.ownerToken ? record : null;
    }
    function operate(handle, operation, argument, baseRevision) {
        const record = lookup(handle);
        if (!record) return { ok: false, error: "STALE_PROVIDER" };
        const current = record.schema && read(record);
        if (!current) return { ok: false, error: "PROVIDER_FAILED" };
        if (baseRevision !== undefined && current.revision !== baseRevision) return { ok: false, error: "REVISION_CONFLICT", ...current };
        if (operation === "apply") {
            const errors = S.validatePatch(record.schema, argument, current.values);
            if (Object.keys(errors).length) return { ok: false, error: "VALIDATION_FAILED", fields: errors, ...current };
            for (const key of Object.keys(argument)) {
                const entry = record.schema.entries.get(key);
                if (!S.enabled(entry, current.values) || !S.visible(entry, current.values)) return { ok: false, error: "DISABLED", ...current };
            }
        }
        if (operation === "invokeAction") {
            const entry = record.schema.entries.get(argument);
            if (!entry || entry.type !== "action") return { ok: false, error: "UNKNOWN_ACTION", ...current };
            if (!S.enabled(entry, current.values) || !S.visible(entry, current.values)) return { ok: false, error: "DISABLED", ...current };
        }
        try {
            const fn = record.descriptor[operation];
            if (typeof fn !== "function") throw new Error("UNSUPPORTED_OPERATION");
            const result = operation === "flush" ? fn.call(record.descriptor) :
                fn.call(record.descriptor, argument, { baseRevision: current.revision, origin: "PbzModConfig" });
            if (!result || typeof result.ok !== "boolean" || typeof result.then === "function" ||
                !Number.isSafeInteger(result.revision) || !S.plain(result.values) ||
                Object.keys(S.validatePatch(record.schema, result.values, result.values)).length ||
                Array.from(record.schema.values.keys()).some(k => !S.own(result.values, k))) throw new Error("INVALID_RESULT");
            const latest = read(record);
            emit({ type: "values", modId: record.modId });
            return { ...result, ...(latest || {}) };
        } catch (e) { fault(record, operation, e); return { ok: false, error: "PROVIDER_FAILED" }; }
    }
    return {
        subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
        setLanguage(value) { const next = L.language(value); if (locale !== next) { locale = next; emit({ type: "language" }); } },
        pages() {
            return Array.from(records.values()).sort((a, b) => a.modId.localeCompare(b.modId)).map(record => {
                const current = record.schema && read(record);
                const handle = { modId: record.modId, ownerToken: record.ownerToken };
                if (!current) return { handle, title: record.modId, modVersion: "", error: record.error, rows: [] };
                const groups = Array.from(record.schema.groups.values()).sort((a, b) => (a.order || 0) - (b.order || 0));
                const rows = [];
                for (const group of [null, ...groups]) {
                    const entries = Array.from(record.schema.entries.values()).filter(e => (e.group || null) === (group?.id || null) && S.visible(e, current.values));
                    if (group && entries.length) rows.push({ id: record.modId + "/group/" + group.id, type: "header", label: L.resolve(group.label, locale) });
                    for (const entry of entries) rows.push({
                        id: record.modId + "/" + entry.key, key: entry.key, type: entry.type,
                        label: L.resolve(entry.label, locale), description: L.resolve(entry.description, locale),
                        value: current.values[entry.key], displayValue: L.format(current.values[entry.key], entry, locale),
                        enabled: S.enabled(entry, current.values), disabledReason: S.enabled(entry, current.values) ? "" : L.resolve(entry.disabledReason, locale),
                        min: entry.min, max: entry.max, step: entry.step, control: entry,
                        minDisplayValue: entry.type === "number" ? L.format(entry.min, entry, locale) : undefined,
                        maxDisplayValue: entry.type === "number" ? L.format(entry.max, entry, locale) : undefined,
                        options: entry.options?.map(o => ({ value: o.value, label: L.resolve(o.label, locale) }))
                    });
                }
                return { handle, title: L.resolve(record.descriptor.displayName, locale), modVersion: record.descriptor.modVersion || "", ...current, rows };
            });
        },
        edit(handle, key, value, revision) { return operate(handle, "apply", { [key]: value }, revision); },
        reset(handle, groupId, revision) { return operate(handle, "reset", groupId, revision); },
        action(handle, key, revision) { return operate(handle, "invokeAction", key, revision); },
        hasVisual(handle) { const r=lookup(handle);return !!r&&!r.error&&typeof r.descriptor.createVisualPreview==="function"; },
        openVisual(handle, context) {
            const generation=stopVisual(),record=lookup(handle);
            if(generation!==visualGeneration)return {ok:false,error:"PREVIEW_CHANGED"};
            if(disposed||!record||typeof record.descriptor.createVisualPreview!=="function")return {ok:false,error:"PREVIEW_UNAVAILABLE"};
            let controller;
            try{
                controller=record.descriptor.createVisualPreview(context);
                if(!controller||typeof controller.update!=="function"||typeof controller.dispose!=="function"||typeof controller.then==="function")throw Error("INVALID_VISUAL_PREVIEW");
                if(generation!==visualGeneration||lookup(handle)!==record){controller.dispose();return {ok:false,error:"PREVIEW_CHANGED"};}
                const own={record,controller};visual=own;
                return {ok:true,update(key,draft){
                    if(visual!==own||lookup(handle)!==record)return false;
                    const current=read(record);if(!current){stopVisual();return false;}
                    const values=S.copy(current.values),entry=record.schema.entries.get(key);
                    // Only a validated color draft may override saved values. Never call apply here.
                    if(draft&&draft.key===key&&draft.revision===current.revision&&entry?.type==="color"&&S.enabled(entry,values)&&S.visible(entry,values)&&!Object.keys(S.validatePatch(record.schema,{[key]:draft.value},values)).length)values[key]=draft.value;
                    try{controller.update({key,values,locale,revision:current.revision});return true;}
                    catch(e){stopVisual();report({code:"VISUAL_PREVIEW_FAILED",detail:String(e)});return false;}
                },dispose(){if(visual===own)stopVisual();}};
            }catch(e){
                if(controller?.dispose)try{controller.dispose();}catch(cleanup){report({code:"VISUAL_PREVIEW_STOP_FAILED",detail:String(cleanup)});}
                report({code:"VISUAL_PREVIEW_FAILED",detail:String(e)});return {ok:false,error:"PREVIEW_FAILED"};
            }
        },
        preview(handle, key, revision) {
            const generation = stopPreview();
            if (generation !== previewGeneration || disposed) return { ok: false, error: "PREVIEW_CHANGED" };
            const record = lookup(handle), current = record && read(record), entry = record?.schema?.entries.get(key);
            if (!current) return { ok: false, error: "STALE_PROVIDER" };
            if (revision !== undefined && revision !== current.revision) return { ok: false, error: "REVISION_CONFLICT" };
            if (entry?.type !== "sound" || typeof record.descriptor.previewSound !== "function") return { ok: false, error: "PREVIEW_UNAVAILABLE" };
            if (!S.enabled(entry, current.values) || !S.visible(entry, current.values)) return { ok: false, error: "DISABLED" };
            try {
                const result = record.descriptor.previewSound(key, { baseRevision: current.revision });
                if (!result?.ok || typeof result.stop !== "function") return { ok: false, error: result?.error || "PREVIEW_FAILED" };
                // Close/cover may run inside the owner's start callback, before
                // its stop function exists. Do not resurrect that canceled start.
                if (generation !== previewGeneration) { result.stop(); return { ok: false, error: "PREVIEW_CHANGED" }; }
                playback = { record, key, value: current.values[key], stop: result.stop };
                const latest = lookup(handle) === record && read(record);
                if (!latest || !record.active || !playback) { stopPreview(); return { ok: false, error: "PREVIEW_CHANGED" }; }
                return { ok: true, durationMs:Number.isFinite(result.durationMs)?Math.max(50,Math.min(5000,result.durationMs)):5000 };
            } catch (e) { stopPreview(); report({ code: "PREVIEW_FAILED", detail: String(e) }); return { ok: false, error: "PREVIEW_FAILED" }; }
        },
        stopPreview,
        flushAll() { return Array.from(records.values()).map(r => ({ modId: r.modId, result: operate(r, "flush") })); },
        dispose() {
            if (disposed) return;
            stopPreview();
            stopVisual();
            const results = this.flushAll();
            disposed = true;
            unsubscribeHub();
            records.forEach(release); records.clear(); listeners.clear();
            return results;
        }
    };
}
module.exports = { createFramework };
