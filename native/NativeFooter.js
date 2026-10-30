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
            if (!shown || !state.acceptsInput() || String(UE.KismetInputLibrary.PointerEvent_GetEffectingButton(event).KeyName) !== "LeftMouseButton") return UE.WidgetBlueprintLibrary.Unhandled();
            if (Date.now() - lastOpen > 750) {
                lastOpen = Date.now();
                try { UE.KismetSystemLibrary.LaunchURL(info.authorUrl); }
                catch (e) { report({ code: "AUTHOR_LINK_FAILED", detail: String(e) }); }
            }
            return UE.WidgetBlueprintLibrary.Handled();
        };
        // This delegate belongs to our new Border, not an original game widget.
        try {
            link.OnMouseButtonDownEvent.Bind(clicked);
            state.scope.own(() => link.OnMouseButtonDownEvent.Unbind());
        } catch (e) { report({ code: "AUTHOR_LINK_UNAVAILABLE", detail: String(e) }); }
    } else report({ code: "AUTHOR_LINK_UNAVAILABLE" });
    return { update(visible) {
        shown = visible === true;
        if (shown) ui.text(text, "PbzModConfig  " + info.version + "\n" + state.word("author") + info.author);
        const visibility = shown ? ui.V.SelfHitTestInvisible : ui.V.Collapsed;
        text.SetVisibility(visibility); box.SetVisibility(visibility);
    } };
}
module.exports = { createFooter };
