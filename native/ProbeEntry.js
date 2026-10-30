"use strict";
const { getHub } = require("../provider/Protocol");
const { createFramework } = require("../src/Framework");
const { inspect } = require("./BoundaryProbe");
const StorageProbe = require("./StorageProbe");
const SLOT = "__PBZ_MOD_CONFIG_PROTOTYPE_V1__";
function install(SettingPanelMixinInterface, UE, puerts, root = globalThis) {
    if (root[SLOT]) return root[SLOT];
    const diagnostic = event => console.warn("[PbzModConfig] " + JSON.stringify(event));
    const state = { version: "0.1.0-prototype", route: "unselected", report: null, framework: createFramework(getHub(root), { report: diagnostic }) };
    const original = SettingPanelMixinInterface.prototype.BP_InitWidget;
    if (typeof original !== "function") throw new Error("SETTING_INIT_ANCHOR_MISSING");
    SettingPanelMixinInterface.prototype.BP_InitWidget = function (...args) {
        const result = original.apply(this, args);
        if (!state.report) {
            // Exactly once after native initialization. Does not add a tab, bind
            // input, clear delegates, patch other scripts or run remote commands.
            state.report = { status: "running" };
            try {
                state.report = { native: inspect(UE, this), storage: StorageProbe.run(UE, puerts) };
                diagnostic({ code: "PROTOTYPE_PROBE", ...state.report });
                if (state.report.storage.root) {
                    const saved = UE.EasyCsv.SaveStringToFile(JSON.stringify(state.report), state.report.storage.root + "/PbzModConfigProbe/report");
                    if (saved !== true) diagnostic({ code: "PROBE_REPORT_WRITE_FAILED" });
                }
            } catch (e) { state.report.error = String(e); diagnostic({ code: "PROBE_FAILED", detail: String(e) }); }
        }
        return result;
    };
    root[SLOT] = state;
    return state;
}
module.exports = { install };
