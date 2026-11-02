"use strict";
const { colorChannels } = require("../provider/Controls");
const EDITORS = "/Game/PBZContent/UI/Settings/Editors/";
const SPEAKER = "/Game/PBZContent/UI/Settings/Texture/T_SecondTab_Settings_ShengYin.T_SecondTab_Settings_ShengYin";
function heldModifiers(UE, owner) {
    // Build 26266538 AbilityWidget.isHeldNodeNavigationKeyDown uses this router.
    // PlayerController.IsInputKeyDown is false under the native menu input mode.
    const router = UE.SubsystemBlueprintLibrary.GetLocalPlayerSubsystem(owner, UE.PBZUIActionRouterBase.StaticClass());
    if (!router || typeof router.IsUIKeyHeld !== "function") throw new Error("MODIFIER_STATE_UNAVAILABLE");
    // This runtime targets Windows. Command queries can report held even
    // without a physical key press; only expose supported chord modifiers.
    return { ...Object.fromEntries([["Ctrl","Control"],["Alt","Alt"],["Shift","Shift"]].map(([name,key])=>
        [name,["Left","Right"].some(side=>router.IsUIKeyHeld(new UE.Key(side+key)))])), Cmd: false };
}
// Language names remain in their own language even while the menu is Chinese.
// The game's rotator otherwise chooses a font from the menu language alone.
function choiceFontFamily(value, locale) {
    const text = String(value ?? "");
    if (/[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]/.test(text)) return "KR";
    if (/[\u0400-\u052f]/.test(text)) return "RU";
    if (/[\u3400-\u9fff]/.test(text)) return text === "繁體中文" || locale === "zhHant" ? "TC" : "CN";
    if (/[\u0102\u0103\u0110\u0111\u01a0\u01a1\u01af\u01b0\u1ea0-\u1ef9]/.test(text) || locale === "vi") return "VN";
    if (/[A-Za-z\u00c0-\u024f]/.test(text)) return "EN";
    return ({ zhHans: "CN", zhHant: "TC", ko: "KR", ru: "RU" })[locale] || "EN";
}
function createChoiceTypography(UE) {
    const styles = new Map();
    return (rotator, value, locale) => {
        // Build 26266538 W_SettingBaseRotator: Construct casts MyText to
        // PBZCommonLocText and stores it in Text. Both refer to the same widget.
        const label = rotator.Text || rotator.MyText;
        if (!label || typeof label.SetFont !== "function") throw new Error("CHOICE_TEXT_FONT_UNAVAILABLE");
        const suffix = choiceFontFamily(value, locale);
        if (!styles.has(suffix)) {
            const base = ["KR", "RU", "TC", "VN"].includes(suffix)
                ? "/Game/PBZContent/UI/Foundation/Text/Textstyle/"
                : "/Game/PBZContent/UI/UINew/System/Character/";
            const name = "Textstyle_Main_" + suffix;
            const style = UE.SGameAIFunctionLibrary.GetClassDefaultObject(UE.Class.Load(base + name + "." + name + "_C"));
            if (!style?.Font?.FontObject) throw new Error("CHOICE_FONT_ASSET_MISSING: " + suffix);
            styles.set(suffix, style);
        }
        const source = styles.get(suffix).Font, font = label.Font;
        // Keep the row's size, outline and material. StartMenu.js uses SetFont
        // after SetPBZFormatText too; applying it after selection avoids the
        // localization decorator replacing the chosen face with the UI font.
        font.FontObject = source.FontObject;
        font.TypefaceFontName = source.TypefaceFontName;
        font.LetterSpacing = source.LetterSpacing;
        label.SetFont(font);
    };
}
function createRows(UE, puerts, ui, tokenOwners, report) {
    const classes = new Map(), bindings = new Map();
    const styleChoice = createChoiceTypography(UE);
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
        let modifiers;
        if (b.state.editors.capturing) {
            try { modifiers = heldModifiers(UE,host); }
            catch(e) { report({code:"KEY_CAPTURE_FAILED",detail:String(e)}); b.state.editors.cancel();return UE.WidgetBlueprintLibrary.Handled(); }
        }
        return b.state.key(b.state.selected || b.id, name, UE.KismetInputLibrary.InputEvent_IsRepeat(event), modifiers)
            ? UE.WidgetBlueprintLibrary.Handled() : UE.WidgetBlueprintLibrary.Unhandled();
    }
    function attach(host, item) {
        release(host);
        const state = tokenOwners.get(item), model = state?.models.get(item);
        if (!state || state.disposed || !model) return;
        const scope = ui.lifetime();
        let row;
        try {
            row = ui.widget(state.panel, cls(({ number: "Scalar", toggle: "Discrete", choice: "Discrete", action: "Discrete", header: "Header" })[model.type]));
            // Scalar's native Tick only positions Text_SettingValue from cached
            // geometry. Keep it active so resizing and first layout stay correct.
            if (model.type !== "number") row.TickFrequency = UE.EWidgetTickFrequency.Never;
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
                    const index = Math.max(0, current.options.findIndex(option => option.value === current.value));
                    fresh.SetSelectedItem(index);
                    styleChoice(fresh, current.options[index]?.label, state.locale);
                };
                if(model.inlineSoundPreview){
                    // The native settings button has an empty Overlay. Keep its
                    // hit target, and draw the game's own Audio-tab brush above it.
                    const preview=ui.widget(state.panel,row.Button_Increase.GetClass());
                    preview.SetIsInteractionEnabled(true);preview.SetIsFocusable(false);
                    preview.SetVisibility(ui.V.Visible);b.controls.push(preview);
                    // Row hosts can have OverlaySlot/BoxSlot roots. Only our own
                    // CanvasPanel promises the anchor/position API used below.
                    const previewLayer=ui.native(state.panel,"CanvasPanel");
                    previewLayer.SetVisibility(ui.V.SelfHitTestInvisible);
                    const layerSlot=root.AddChild(previewLayer);
                    if(layerSlot.SetHorizontalAlignment)layerSlot.SetHorizontalAlignment(UE.EHorizontalAlignment.HAlign_Fill);
                    if(layerSlot.SetVerticalAlignment)layerSlot.SetVerticalAlignment(UE.EVerticalAlignment.VAlign_Fill);
                    scope.own(()=>previewLayer.RemoveFromParent());
                    const anchors=new UE.Anchors();
                    anchors.Minimum=new UE.Vector2D(1,.5);anchors.Maximum=anchors.Minimum;
                    const place=(widget,width,height,right)=>{
                        const slot=previewLayer.AddChildToCanvas(widget);
                        slot.SetAnchors(anchors);slot.SetAlignment(new UE.Vector2D(1,.5));
                        slot.SetPosition(new UE.Vector2D(-right,0));slot.SetSize(new UE.Vector2D(width,height));
                    };
                    place(preview,76,60,22);
                    const icon=ui.native(state.panel,"Image"),texture=UE.Object.Load(SPEAKER);
                    if(!ui.valid(texture))throw Error("PREVIEW_SPEAKER_ASSET_MISSING");
                    icon.SetBrushFromTexture(texture);icon.SetVisibility(ui.V.HitTestInvisible);place(icon,42,42,39);
                    scope.own(()=>icon.RemoveFromParent());
                    // Build 26266538: Button_Decrease/Increase are CHILDREN of
                    // their Overlays. Translating both moves the hitbox twice.
                    for(const w of [fresh,row.DecreaseOverlay,row.IncreaseOverlay])w.SetRenderTranslation(new UE.Vector2D(-120,0));
                    scope.own(()=>preview.RemoveFromParent());
                    scope.bind(preview.OnButtonBaseClicked,()=>{if(editable())state.previewSound(b.id);});
                    b.refreshValue=(selected=state.selected===b.id)=>{
                        const m=state.models.get(item),ink=selected?.08:1;
                        icon.SetColorAndOpacity(new UE.LinearColor(ink,ink,ink,m?.previewPlaying?1:.68));
                        icon.SetRenderOpacity(m?.enabled===false?.4:1);
                    };
                    const update=b.update;b.update=current=>{
                        update(current);b.refreshValue();
                    };
                    b.previewControl=preview;b.previewIcon=icon;
                }
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
                // Build 26266538 native Scalar: browse = fixed current value;
                // selected = both range endpoints + separate thumb-following value.
                // Do not replace the maximum with the current value.
                const fixed=row.CurrentValue,cursor=row.Text_SettingValue;
                const left=row.Text_LeftValue||row.LeftValue,right=row.Text_RightValue||row.RightValue;
                if(![fixed,cursor,left,right].every(ui.valid)||typeof row.UpdateCursorTextPosition!=="function")throw new Error("SCALAR_VALUE_LAYOUT_UNAVAILABLE");
                b.refreshValue=(selected=state.selected===b.id)=>{
                    const m=state.models.get(item);if(!m||!scope.live)return;
                    ui.text(fixed,m.displayValue);ui.text(cursor,m.displayValue);
                    ui.text(left,m.minDisplayValue);ui.text(right,m.maxDisplayValue);
                    fixed.SetRenderOpacity(1);cursor.SetRenderOpacity(1);
                    fixed.SetVisibility(selected?ui.V.Hidden:ui.V.SelfHitTestInvisible);
                    for(const label of [left,right,cursor])label.SetVisibility(selected?ui.V.SelfHitTestInvisible:ui.V.Hidden);
                    // Native function safely waits for nonzero cached geometry; native
                    // Tick handles the first completed layout and subsequent resizes.
                    row.UpdateCursorTextPosition();
                };
                b.update = m => {
                    fresh.SetStepSize(m.step / (m.max - m.min));
                    fresh.SetValue((m.value - m.min) / (m.max - m.min));
                    b.refreshValue();
                };
            } else if (model.type === "action") {
                // Build 26266538 W_SettingBaseButton (used by the Action row)
                // contains only an empty Overlay. SetButtonText cannot render
                // a binding there. Reuse the native, localized value control.
                const fresh = button(row.Rotator_SettingValue, () => state.action(b.id));
                row.Rotator_SettingValue = fresh; b.control = fresh;
                // This value opens an editor; it must not look like a cycle.
                row.Button_Decrease.SetVisibility(ui.V.Collapsed);
                row.Button_Increase.SetVisibility(ui.V.Collapsed);
                // Arrows are siblings of the buttons. Native selection can
                // show their overlays again; detach the decorations entirely.
                row.DecreaseOverlay.RemoveFromParent();
                row.IncreaseOverlay.RemoveFromParent();
                fresh.OptionsScalingSizeBox.RemoveFromParent();
                b.update = m => {
                    const value = m.buttonLabel || m.label, labels = UE.NewArray(UE.BuiltinText);
                    labels.Add(ui.asText(value));
                    fresh.PopulateTextLabels(labels);
                    fresh.SetSelectedItem(0);
                    styleChoice(fresh, value, state.locale);
                };
            } else {
                b.update = () => {};
            }
            if (model.colorPreview) {
                const swatch = ui.native(row,"Image"), texture=UE.Object.Load("/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture");
                if(!texture)throw new Error("COLOR_PREVIEW_TEXTURE_MISSING");
                swatch.SetBrushFromTexture(texture,false);swatch.SetVisibility(ui.V.HitTestInvisible);
                const previewSlot=root.AddChild(swatch);
                if(typeof previewSlot.SetAnchors === "function") {
                    const anchors=new UE.Anchors();anchors.Minimum=new UE.Vector2D(1,0.5);anchors.Maximum=new UE.Vector2D(1,0.5);
                    previewSlot.SetAnchors(anchors);previewSlot.SetAlignment(new UE.Vector2D(1,0.5));
                    previewSlot.SetPosition(new UE.Vector2D(-220,0));previewSlot.SetSize(new UE.Vector2D(28,28));
                } else {
                    if(typeof swatch.SetDesiredSizeOverride === "function")swatch.SetDesiredSizeOverride(new UE.Vector2D(28,28));
                    previewSlot.SetHorizontalAlignment(UE.EHorizontalAlignment.HAlign_Right);previewSlot.SetVerticalAlignment(UE.EVerticalAlignment.VAlign_Center);
                    const padding=new UE.Margin();padding.Right=220;previewSlot.SetPadding(padding);
                }
                scope.own(()=>swatch.RemoveFromParent());
                const update=b.update;
                b.update=m=>{
                    update(m);
                    const channels=colorChannels(m.colorPreview), linear=v=>{v/=255;return v<=0.04045?v/12.92:Math.pow((v+0.055)/1.055,2.4);};
                    swatch.SetColorAndOpacity(new UE.LinearColor(...channels.slice(0,3).map(linear),(channels[3]??255)/255));
                };
            }
            b.refresh = m => {
                b.applying = true;
                try {
                    ui.text(row.Text_SettingName, m.label);
                    if ((m.type === "header" || m.section) && row.Text_SettingName) {
                        // Runtime-created native headings retain their default
                        // justification unless explicitly aligned with setting names.
                        row.Text_SettingName.SetJustification(UE.ETextJustify.Left);
                        const nameSlot = row.Text_SettingName.Slot;
                        if (nameSlot && typeof nameSlot.SetHorizontalAlignment === "function") nameSlot.SetHorizontalAlignment(UE.EHorizontalAlignment.HAlign_Fill);
                    }
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
            b.refreshValue?.(selected);
            if (selected) b.state.select(b.id, false);
        }
        OnMouseEnter() { const b = bindings.get(this); if (b?.state.acceptsInput()) b.state.select(b.id, false); }
        OnMouseButtonDown(geometry, event) {
            const b = bindings.get(this);
            const model = b?.state.models.get(b.item);
            if (b?.scope.live && !b.applying && b.state.acceptsInput() && model?.type === "action" && model.enabled !== false &&
                (!b.state.editors.capturing || ["cancel", "clear"].includes(model.editorAction)) &&
                typeof UE.KismetInputLibrary.PointerEvent_GetEffectingButton === "function" &&
                String(UE.KismetInputLibrary.PointerEvent_GetEffectingButton(event).KeyName) === "LeftMouseButton") {
                b.state.action(b.id); return UE.WidgetBlueprintLibrary.Handled();
            }
            return UE.WidgetBlueprintLibrary.Unhandled();
        }
        OnAddedToFocusPath() { const b = bindings.get(this); if (b?.state.acceptsInput()) b.state.select(b.id, false); }
        OnPreviewKeyDown(geometry, event) { return key(this, event); }
        OnKeyUp(geometry,event) {
            const b=bindings.get(this),name=String(UE.KismetInputLibrary.GetKey(event).KeyName);
            return b?.state.acceptsInput() && b.state.keyUp(name) ? UE.WidgetBlueprintLibrary.Handled() : UE.WidgetBlueprintLibrary.Unhandled();
        }
        OnPreviewMouseButtonDown(geometry,event) {
            const b=bindings.get(this);
            if(!b?.state.acceptsInput() || !b.state.editors.capturing)return UE.WidgetBlueprintLibrary.Unhandled();
            const model=b.state.models.get(b.item);
            if(["cancel","clear"].includes(model?.editorAction))return UE.WidgetBlueprintLibrary.Unhandled();
            try {
                const name=String(UE.KismetInputLibrary.PointerEvent_GetEffectingButton(event).KeyName);
                b.state.editors.key(name,false,heldModifiers(UE,this));b.state.refresh();
            } catch(e) {report({code:"KEY_CAPTURE_FAILED",detail:String(e)});b.state.editors.cancel();}
            return UE.WidgetBlueprintLibrary.Handled();
        }
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
module.exports = { createRows, choiceFontFamily, createChoiceTypography, heldModifiers, SPEAKER };
