"use strict";
// Isolated capability experiment, not a menu implementation or a fallback route.
// Never assigns JS closures to C++ GameSettingDataSourceDynamic setters/getters.
function members(object) {
    const output = new Set();
    for (let p = object, depth = 0; p && depth < 8; p = Object.getPrototypeOf(p), depth++) {
        for (const name of Object.getOwnPropertyNames(p)) output.add(name);
    }
    return Array.from(output).sort();
}
function inspect(UE, panel) {
    const report = { build: "26266538", kind: "reflection-probe", status: "incomplete", classes: {}, panel: {}, collectionExperiment: null };
    const created = {};
    for (const name of ["GameSettingCollection", "GameSettingValueScalarDynamic", "GameSettingValueDiscreteDynamic_Bool", "GameSettingAction"]) {
        try {
            const type = UE[name];
            if (!type || typeof type.StaticClass !== "function") throw new Error("CLASS_NOT_EXPOSED");
            const object = UE.NewObject(type.StaticClass(), panel);
            if (!object) throw new Error("NEW_OBJECT_FAILED");
            created[name] = object;
            report.classes[name] = { status: "created", members: members(object),
                callable: Object.fromEntries(["AddSetting", "GetChildSettings", "SetDynamicGetter", "SetDynamicSetter", "SetDevName", "SetDisplayName"].map(k => [k, typeof object[k] === "function"])) };
        } catch (e) { report.classes[name] = { status: "failed", error: String(e) }; }
    }
    for (const name of ["Registry", "SettingCollections", "ListView_Settings", "Details_Settings", "W_OverlayTabList_C"]) {
        try { report.panel[name] = panel[name] ? { members: members(panel[name]) } : { missing: true }; }
        catch (e) { report.panel[name] = { error: String(e) }; }
    }
    try {
        const collection = created.GameSettingCollection, child = created.GameSettingAction;
        if (!collection || !child || typeof collection.AddSetting !== "function" || typeof collection.GetChildSettings !== "function") throw new Error("COLLECTION_REGISTRATION_NOT_REFLECTED");
        collection.AddSetting(child); // isolated scratch collection, never the live Registry.
        const children = collection.GetChildSettings();
        if (children.Num() !== 1 || children.Get(0) !== child) throw new Error("COLLECTION_READBACK_MISMATCH");
        report.collectionExperiment = { status: "passed-isolated-collection" };
    } catch (e) { report.collectionExperiment = { status: "failed", error: String(e) }; }
    report.status = "observed";
    report.route = "unselected";
    report.remaining = ["dynamic-data-source-construction-and-readwrite", "live-registry-paired-tab-registration", "native-row-input-focus"];
    return report;
}
module.exports = { inspect, members };
