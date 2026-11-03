"use strict";
const info = require("../src/Metadata");
function createFooter(UE, ui, state, report) {
    const view = state.detailView, text = view.RichText_DynamicDetails, box = view.Box_DetailsExtension;
    if (!ui.valid(text) || !ui.valid(box)) throw new Error("NATIVE_FOOTER_MISSING");
    const link = ui.native(view, "Border"), slot = box.AddChild(link);
    ui.copySlot(text.Slot, slot);
    text.RemoveFromParent();
    const transparent = new UE.LinearColor(); transparent.A = 0;
    link.SetBrushColor(transparent); link.SetPadding(new UE.Margin());
    link.SetContent(text); link.SetRenderOpacity(0.6);
    text.SetVisibility(ui.V.Collapsed); box.SetVisibility(ui.V.Collapsed);
    let lastOpen = 0, shown = false;
    if (typeof UE.KismetSystemLibrary.LaunchURL === "function" && typeof UE.KismetInputLibrary.PointerEvent_GetEffectingButton === "function") {
        const clicked = (geometry, event) => {
            if (!state.scope.live || state.disposed) return UE.WidgetBlueprintLibrary.Unhandled();
            try {
                if (!shown || !state.acceptsInput() || String(UE.KismetInputLibrary.PointerEvent_GetEffectingButton(event).KeyName) !== "LeftMouseButton") return UE.WidgetBlueprintLibrary.Unhandled();
                if (Date.now() - lastOpen > 750) {
                    lastOpen = Date.now();
                    UE.KismetSystemLibrary.LaunchURL(info.authorUrl);
                }
                return UE.WidgetBlueprintLibrary.Handled();
            } catch (e) {
                state.fail(e, "AUTHOR_LINK_INPUT_FAILED");
                return UE.WidgetBlueprintLibrary.Unhandled();
            }
        };
        // This delegate belongs to our new Border, not an original game widget.
        // Register cleanup first; a partially successful Bind must also unwind
        // through the owning menu's creation boundary.
        state.scope.own(() => link.OnMouseButtonDownEvent.Unbind());
        link.OnMouseButtonDownEvent.Bind(clicked);
    } else report({ code: "AUTHOR_LINK_UNAVAILABLE" });
    return { update(visible) {
        shown = visible === true;
        if (shown) ui.text(text, "PbzModConfig  " + info.version + "\n" + state.word("author") + info.author);
        const visibility = shown ? ui.V.SelfHitTestInvisible : ui.V.Collapsed;
        text.SetVisibility(visibility); box.SetVisibility(visibility);
    } };
}
module.exports = { createFooter };
