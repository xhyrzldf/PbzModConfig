"use strict";
function isDestroyedObjectError(error) {
    return error?.message === "passing a invalid object" || error?.message === "access a invalid object";
}
// Runtime-owned widgets only. No original asset, delegate list or input mapping is replaced.
function createSupport(UE, report) {
    const V = UE.ESlateVisibility;
    const valid = value => {
        if (!value) return false;
        // Build 26266538 can throw before IsValid receives a destroyed wrapper.
        try { return UE.KismetSystemLibrary.IsValid(value); }
        catch (error) { if (isDestroyedObjectError(error)) return false; throw error; }
    };
    const is = (object, name) => !!object && !!UE[name] && object.IsA(UE[name].StaticClass());
    const widget = (owner, cls) => {
        const result = UE.WidgetBlueprintLibrary.Create(owner, cls, owner.GetOwningPlayer());
        if (!valid(result)) throw new Error("WIDGET_CREATE_FAILED");
        return result;
    };
    const native = (owner, cls) => {
        const result = UE.NewObject(typeof cls === "string" ? UE[cls].StaticClass() : cls, owner.WidgetTree);
        if (!valid(result)) throw new Error("NATIVE_CREATE_FAILED: " + cls);
        return result;
    };
    const asText = value => UE.KismetTextLibrary.Conv_StringToText(String(value ?? ""));
    function text(label, value) {
        if (!valid(label)) return;
        // PuerTS does not implicitly turn a JavaScript string into FText in this build.
        const nativeText = asText(value);
        if (typeof label.SetPBZFormatText === "function") label.SetPBZFormatText(nativeText);
        else label.SetText(nativeText);
    }
    function lifetime(onFailure) {
        let live = true;
        const releases = [];
        const scope = {
            get live() { return live; },
            own(release) { if (live) releases.push(release); else release(); },
            bind(delegate, handler) {
                if (!delegate || typeof delegate.Add !== "function" || typeof delegate.Remove !== "function") throw new Error("DELEGATE_NOT_EXPOSED");
                const wrapped = (...args) => {
                    if (!live) return;
                    try { handler(...args); } catch (e) {
                        if (onFailure) {
                            try { onFailure(e); } catch (_) { report({ code: "UI_FAILURE_HANDLER_FAILED" }); }
                        } else report({ code: "UI_CALLBACK_FAILED", detail: String(e) });
                    }
                };
                // Register removal first: an Add that partially succeeds must also unwind.
                scope.own(() => delegate.Remove(wrapped));
                delegate.Add(wrapped);
                return wrapped;
            },
            dispose() {
                if (!live) return;
                live = false;
                for (const release of releases.splice(0).reverse()) {
                    try { release(); } catch (e) {
                        if (!isDestroyedObjectError(e)) report({ code: "UI_RELEASE_FAILED", detail: String(e) });
                    }
                }
            }
        };
        return scope;
    }
    function copySlot(from, to) {
        if (!from || !to) throw new Error("LAYOUT_SLOT_MISSING");
        if (is(from, "CanvasPanelSlot")) {
            to.SetAnchors(from.GetAnchors());
            to.SetAlignment(from.GetAlignment());
            to.SetOffsets(from.GetOffsets());
            to.SetAutoSize(from.GetAutoSize());
            to.SetZOrder(from.GetZOrder());
        } else {
            if (typeof to.SetPadding === "function" && from.Padding !== undefined) to.SetPadding(from.Padding);
            if (typeof to.SetHorizontalAlignment === "function" && from.HorizontalAlignment !== undefined) to.SetHorizontalAlignment(from.HorizontalAlignment);
            if (typeof to.SetVerticalAlignment === "function" && from.VerticalAlignment !== undefined) to.SetVerticalAlignment(from.VerticalAlignment);
            if (typeof to.SetSize === "function" && from.Size !== undefined) to.SetSize(from.Size);
        }
    }
    function replaceControl(row, old, fresh) {
        if (!valid(old) || !valid(fresh)) throw new Error("INPUT_CONTROL_MISSING");
        const parent = old.GetParent(), slot = old.Slot;
        if (!valid(parent) || !slot) throw new Error("INPUT_LAYOUT_MISSING");
        if (is(parent, "ContentWidget")) {
            const saved = { Padding: slot.Padding, HorizontalAlignment: slot.HorizontalAlignment, VerticalAlignment: slot.VerticalAlignment };
            const target = parent.SetContent(fresh);
            if (saved.Padding !== undefined) target.SetPadding(saved.Padding);
            if (saved.HorizontalAlignment !== undefined) target.SetHorizontalAlignment(saved.HorizontalAlignment);
            if (saved.VerticalAlignment !== undefined) target.SetVerticalAlignment(saved.VerticalAlignment);
        } else {
            copySlot(slot, parent.AddChild(fresh));
            old.SetVisibility(V.Collapsed);
        }
        // These ancestors are all inside our newly created row.
        let child = fresh;
        for (let i = 0; child && i < 24; i++) {
            child.SetIsEnabled(true);
            child.SetVisibility(child === fresh ? V.Visible : V.SelfHitTestInvisible);
            const ancestor = child.GetParent();
            if (is(ancestor, "WidgetSwitcher")) ancestor.SetActiveWidget(child);
            if (child === row) break;
            child = ancestor;
        }
    }
    function container(owner, source) {
        const kind = ["CanvasPanel", "Overlay", "SizeBox"].find(k => is(source, k));
        if (!kind) throw new Error("UNSUPPORTED_NATIVE_LAYOUT");
        const copy = native(owner, kind);
        if (kind === "SizeBox") for (const key of ["WidthOverride", "HeightOverride", "MinDesiredWidth", "MinDesiredHeight", "MaxDesiredWidth", "MaxDesiredHeight", "MinAspectRatio", "MaxAspectRatio"]) {
            if (source["bOverride_" + key]) copy["Set" + key](source[key]);
        }
        return copy;
    }
    function mount(owner, list, details) {
        const switcher = owner.WidgetSwitcher_65, copies = new Map();
        let source = owner.ListView_Settings, content = list;
        let detailSource = owner.Details_Settings, detailRoot = details, external = false;
        const created = [], edges = [];
        try {
            for (let i = 0; i < 24; i++) {
                const parent = source.GetParent();
                if (!valid(parent)) throw new Error("SETTINGS_SWITCHER_NOT_FOUND");
                if (parent === switcher) {
                    copySlot(source.Slot, switcher.AddChild(content));
                    break;
                }
                const copy = container(owner, parent);
                copies.set(parent, copy);
                copySlot(source.Slot, copy.AddChild(content));
                source = parent; content = copy;
            }
            if (content.GetParent() !== switcher) throw new Error("SETTINGS_LAYOUT_TOO_DEEP");
            const root = content;
            // Find a common ancestor BEFORE mounting; a direct parent can be inside the hidden native page.
            let join = null;
            for (let i = 0; i < 24; i++) {
                const parent = detailSource.GetParent();
                if (!valid(parent)) break;
                if (copies.has(parent)) { join = copies.get(parent); break; }
                edges.push({ parent, slot: detailSource.Slot }); detailSource = parent;
            }
            if (join) {
                for (const edge of edges) {
                    const copy = container(owner, edge.parent); created.push(copy);
                    copySlot(edge.slot, copy.AddChild(detailRoot)); detailRoot = copy;
                }
                copySlot(detailSource.Slot, join.AddChild(detailRoot));
            } else {
                detailSource = owner.Details_Settings;
                const parent = detailSource.GetParent();
                if (!valid(parent) || is(parent, "ContentWidget")) throw new Error("DETAILS_LAYOUT_MISSING");
                copySlot(detailSource.Slot, parent.AddChild(detailRoot)); external = true;
            }
            return { root, detailRoot, external, originalDetails: detailSource };
        } catch (e) {
            // No layout has been returned yet: unwind every owned widget here,
            // including failures during the first list attachment. Never touch originals.
            for (const owned of new Set([content, detailRoot, list, details, ...copies.values(), ...created])) {
                try { if (valid(owned)) owned.RemoveFromParent(); }
                catch (cleanup) {
                    if (!isDestroyedObjectError(cleanup)) {
                        try { report({code:"LAYOUT_ROLLBACK_FAILED", detail:String(cleanup)}); } catch (_) {}
                    }
                }
            }
            throw e;
        }
    }
    return { V, valid, is, widget, native, asText, text, lifetime, copySlot, replaceControl, mount };
}
module.exports = { createSupport, isDestroyedObjectError };
