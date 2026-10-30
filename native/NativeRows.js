"use strict";
const EDITORS = "/Game/PBZContent/UI/Settings/Editors/";
function createRows(UE, puerts, ui, tokenOwners, report) {
    const classes = new Map(), bindings = new Map();
    function cls(kind) {
        const name = "W_SettingsListEntry_" + kind;
        if (!classes.has(kind)) {
            const type = UE.Class.Load(EDITORS + name + "." + name + "_C");
            if (!type) throw new Error("ROW_ASSET_MISSING: " + kind);
            classes.set(kind, type);
        }
        return classes.get(kind);
    }
    function release(host) {
        const binding = bindings.get(host);
        if (!binding) return;
        bindings.delete(host);
        binding.scope.dispose();
        if (binding.state.entries.get(binding.id) === binding) binding.state.entries.delete(binding.id);
        if (ui.valid(binding.row)) binding.row.RemoveFromParent();
    }
    function key(host, event) {
        const b = bindings.get(host);
        if (!b || !b.state.acceptsInput()) return UE.WidgetBlueprintLibrary.Unhandled();
        const name = String(UE.KismetInputLibrary.GetKey(event).KeyName);
        return b.state.key(b.state.selected || b.id, name, UE.KismetInputLibrary.InputEvent_IsRepeat(event))
            ? UE.WidgetBlueprintLibrary.Handled() : UE.WidgetBlueprintLibrary.Unhandled();
    }
    function attach(host, item) {
        release(host);
        const state = tokenOwners.get(item), model = state?.models.get(item);
        if (!state || state.disposed || !model) return;
        const scope = ui.lifetime();
        let row;
        try {
            row = ui.widget(state.panel, cls(({ number: "Scalar", toggle: "Discrete", choice: "Discrete", action: "Action", header: "Header" })[model.type]));
            row.TickFrequency = UE.EWidgetTickFrequency.Never;
            row.SetVisibility(ui.V.SelfHitTestInvisible);
            const root = host.WidgetTree.RootWidget;
            for (let i = 0; i < root.GetChildrenCount(); i++) root.GetChildAt(i).SetVisibility(ui.V.Collapsed);
            const slot = root.AddChild(row);
            if (slot.SetHorizontalAlignment) slot.SetHorizontalAlignment(UE.EHorizontalAlignment.HAlign_Fill);
            if (slot.SetVerticalAlignment) slot.SetVerticalAlignment(UE.EVerticalAlignment.VAlign_Fill);
            const b = { state, id: model.id, item, host, row, scope, applying: false, control: null, controls: [], update: null };
            bindings.set(host, b); state.entries.set(model.id, b);
            const editable = () => !b.applying && scope.live && state.acceptsInput() && state.models.has(item) && state.models.get(item).enabled !== false;
            const changed = value => { if (editable()) state.edit(b.id, value); };
            const button = (old, callback) => {
                const fresh = ui.widget(state.panel, old.GetClass());
                ui.replaceControl(row, old, fresh);
                fresh.SetIsInteractionEnabled(true);
                fresh.SetIsFocusable(true);
                scope.bind(fresh.OnButtonBaseClicked, () => { if (editable()) { state.select(b.id, false); callback(); } });
                b.controls.push(fresh);
                return fresh;
            };
            if (model.type === "toggle" || model.type === "choice") {
                const old = row.Rotator_SettingValue;
                const fresh = ui.widget(state.panel, old.GetClass());
                ui.replaceControl(row, old, fresh); row.Rotator_SettingValue = fresh;
                fresh.SetIsInteractionEnabled(true); fresh.SetIsFocusable(true);
                b.control = fresh; b.controls.push(fresh);
                scope.bind(fresh.OnRotated, () => {
                    const current = state.models.get(item);
                    const option = current?.options?.[fresh.GetSelectedIndex()];
                    if (option) changed(option.value);
                });
                scope.bind(fresh.OnButtonBaseClicked, () => { if (editable()) state.step(b.id, 1); });
                row.Button_Decrease = button(row.Button_Decrease, () => state.step(b.id, -1));
                row.Button_Increase = button(row.Button_Increase, () => state.step(b.id, 1));
                b.update = current => {
                    const labels = UE.NewArray(UE.BuiltinText);
                    current.options.forEach(option => labels.Add(ui.asText(option.label)));
                    fresh.PopulateTextLabels(labels);
                    fresh.SetSelectedItem(Math.max(0, current.options.findIndex(option => option.value === current.value)));
                };
            } else if (model.type === "number") {
                const old = row.Slider_SettingValue, fresh = ui.native(row, old.GetClass());
                // Copy the game's actual Slate/material styles, never substitute a generic slider.
                fresh.WidgetStyle = old.WidgetStyle;
                for (const field of ["Textstyle", "TextStyleCJK", "BarMaterial", "FilledBarTint", "UnfilledBarTint", "Orientation", "IndentHandle", "MouseUsesStep", "RequiresControllerLock"]) {
                    if (old[field] !== undefined) fresh[field] = old[field];
                }
                ui.replaceControl(row, old, fresh); row.Slider_SettingValue = fresh;
                fresh.SetMinValue(0); fresh.SetMaxValue(1);
                b.control = fresh; b.controls.push(fresh);
                scope.bind(fresh.OnValueChanged, value => {
                    const m = state.models.get(item);
                    if (!m || !editable()) return;
                    const steps = Math.round((m.max - m.min) / m.step);
                    changed(Number((m.min + Math.round(Math.max(0, Math.min(1, value)) * steps) * m.step).toFixed(10)));
                });
                for (const name of ["OnMouseCaptureEnd", "OnControllerCaptureEnd"]) scope.bind(fresh[name], () => { if (editable()) state.flush(); });
                row.Button_Decrease = button(row.Button_Decrease, () => state.step(b.id, -1));
                row.Button_Increase = button(row.Button_Increase, () => state.step(b.id, 1));
                row.InitCachedTexts();
                b.update = m => {
                    fresh.SetStepSize(m.step / (m.max - m.min));
                    fresh.SetValue((m.value - m.min) / (m.max - m.min));
                    fresh.SetDisplayValue(ui.asText(m.displayValue));
                    ui.text(row.Text_LeftValue || row.LeftValue, m.minDisplayValue);
                    ui.text(row.Text_RightValue || row.RightValue, m.maxDisplayValue);
                    // PBZSettingSlider supplies its native thumb label. Hide the stale row duplicate.
                    for (const name of ["CurrentValue", "Text_SettingValue"]) if (ui.valid(row[name])) row[name].SetVisibility(ui.V.Collapsed);
                };
            } else if (model.type === "action") {
                const fresh = button(row.Button_Action, () => state.action(b.id));
                row.Button_Action = fresh; b.control = fresh;
                b.update = m => fresh.SetButtonText(ui.asText(m.buttonLabel || m.label));
            } else {
                b.update = () => {};
            }
            b.refresh = m => {
                b.applying = true;
                try {
                    ui.text(row.Text_SettingName, m.label);
                    b.update(m);
                    // Leave the row focusable so the disabled reason remains discoverable.
                    for (const control of b.controls) control.SetIsEnabled(m.enabled !== false);
                } finally { b.applying = false; }
            };
            b.refresh(model);
            state.rowReady(b);
        } catch (e) {
            release(host); scope.dispose();
            if (ui.valid(row)) row.RemoveFromParent();
            report({ code: "ROW_CREATE_FAILED", id: model.id, detail: String(e) });
            // A bad provider row must not remove the whole settings page.
            ui.text(host.Text_SettingName, model.label + " — " + state.word("unavailable"));
            if (host.Text_SettingName) host.Text_SettingName.SetVisibility(ui.V.SelfHitTestInvisible);
        }
    }
    class RowHost {
        OnListItemObjectSet(item) { attach(this, item); }
        BP_OnEntryReleased() { release(this); }
        BP_OnItemSelectionChanged(selected) {
            const b = bindings.get(this);
            if (!b) return;
            b.row.SetSelected(selected);
            if (selected) b.state.select(b.id, false);
        }
        OnMouseEnter() { const b = bindings.get(this); if (b?.state.acceptsInput()) b.state.select(b.id, false); }
        OnMouseButtonDown(geometry, event) {
            const b = bindings.get(this);
            if (b?.state.acceptsInput() && b.state.models.get(b.item)?.section &&
                typeof UE.KismetInputLibrary.PointerEvent_GetEffectingButton === "function" &&
                String(UE.KismetInputLibrary.PointerEvent_GetEffectingButton(event).KeyName) === "LeftMouseButton") {
                b.state.action(b.id); return UE.WidgetBlueprintLibrary.Handled();
            }
            return UE.WidgetBlueprintLibrary.Unhandled();
        }
        OnAddedToFocusPath() { const b = bindings.get(this); if (b?.state.acceptsInput()) b.state.select(b.id, false); }
        OnPreviewKeyDown(geometry, event) { return key(this, event); }
        OnAnalogValueChanged(geometry, event) {
            const b = bindings.get(this);
            if (!b?.state.acceptsInput()) return UE.WidgetBlueprintLibrary.Unhandled();
            const name = String(UE.KismetInputLibrary.GetKey(event).KeyName);
            const value = UE.KismetInputLibrary.GetAnalogValue(event);
            return b.state.analog(b.state.selected || b.id, name, value) ? UE.WidgetBlueprintLibrary.Handled() : UE.WidgetBlueprintLibrary.Unhandled();
        }
        GetPrimaryGamepadFocusWidget() { return bindings.get(this)?.control || this; }
    }
    const config = { inherit: true };
    puerts.blueprint.mixin(puerts.blueprint.tojs(cls("Header")), RowHost, config);
    if (!config.generatedClass) throw new Error("ROW_HOST_CLASS_NOT_CREATED");
    return { entryClass: config.generatedClass, release, releaseState(state) {
        for (const [host, binding] of Array.from(bindings)) if (binding.state === state) release(host);
    } };
}
module.exports = { createRows };
