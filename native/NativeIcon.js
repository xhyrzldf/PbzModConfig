"use strict";
function createIconLoader(UE, ui, report) {
    let cached, attempted = false;
    return owner => {
        if (ui.valid(cached)) return cached;
        if (cached) attempted = false; // A collected transient texture can be imported for a new panel.
        if (!attempted) {
            attempted = true;
            try {
                const path = UE.BlueprintPathsLibrary.ProjectContentDir() + "JavaScript/PbzModConfig/assets/modconfig-icon.png";
                cached = UE.KismetRenderingLibrary.ImportFileAsTexture2D(owner, path);
                if (!ui.valid(cached)) throw new Error("PNG_IMPORT_RETURNED_NULL");
                report({ code: "CUSTOM_ICON_LOADED" });
                return cached;
            } catch (e) { report({ code: "CUSTOM_ICON_FAILED", detail: String(e) }); }
        }
        // A failed cosmetic asset must not remove access to the configuration page.
        return UE.Object.Load("/Game/PBZContent/UI/Settings/Texture/T_Setting_Icon.T_Setting_Icon");
    };
}
module.exports = { createIconLoader };
