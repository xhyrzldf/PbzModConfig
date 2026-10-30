"use strict";
// In a business package these three files live in its own private namespace.
const { createStore } = require("../provider/ConfigStore");
const { createJournal } = require("../provider/Journal");
const { publishOptional } = require("../provider/Protocol");
const T = require("./Translations");
function descriptor(modId = "PbzConfigDemo") {
    return {
        apiVersion: 1, modId, modVersion: "0.2.2-preview", schemaVersion: 1,
        displayName: T.title,
        groups: [{ id: "display", label: T.display, order: 0 }],
        entries: [
            { key: "enabled", type: "toggle", group: "display", label: T.enabled,
                description: T.enabledHelp, defaultValue: true },
            { key: "opacity", type: "number", group: "display", label: T.opacity,
                description: T.opacityHelp,
                defaultValue: 0.8, min: 0.2, max: 1, step: 0.05, format: "P0", enabledWhen: { key: "enabled", equals: true },
                disabledReason: T.disabled },
            { key: "placement", type: "choice", group: "display", label: T.placement, defaultValue: "right",
                options: [{ value: "left", label: T.left }, { value: "right", label: T.right }] },
            { key: "about", type: "header", label: T.saving },
            { key: "save", type: "action", label: T.save }
        ]
    };
}
function createDemo(io, options = {}) {
    const spec = descriptor(options.modId);
    const store = createStore(spec, createJournal(io, spec.modId, options.report), {
        ...options, actions: { save: ({ flush }) => flush() }
    });
    const registration = publishOptional(store, options.root || globalThis, options.report);
    return { store, registration, dispose() {
        const outcome = store.dispose();
        if (outcome.ok) registration.dispose();
        return outcome;
    } };
}
module.exports = { descriptor, createDemo };
