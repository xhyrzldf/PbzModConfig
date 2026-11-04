"use strict";

// The official methods own their private WeakMap. Track only the timer created
// by each public method, including repetitions of the same polling callback.
function createNativeSelectionLifecycle(Panel, timerRoot = globalThis) {
    const originalPending = Panel.prototype.selectFirstSettingDeferred;
    const originalFocus = Panel.prototype.SelectWidgetToFocus;
    if (typeof originalPending !== "function" || typeof originalFocus !== "function") {
        throw new Error("NATIVE_SELECTION_METHOD_MISSING");
    }
    const states = new WeakMap();
    const liveStates = new Set();
    let stopped = false;

    function getState(panel) {
        let state = states.get(panel);
        if (!state) {
            state = {
                pending: { generation: 0, handles: new Set() },
                focus: { generation: 0, handles: new Set() }
            };
            states.set(panel, state);
            liveStates.add(state);
        }
        return state;
    }

    function cancel(lane) {
        lane.generation++;
        for (const handle of lane.handles) timerRoot.clearTimeout(handle);
        lane.handles.clear();
    }

    function capture(panel, name, original, args) {
        if (stopped) throw new Error("NATIVE_SELECTION_LIFECYCLE_STOPPED");
        const lane = getState(panel)[name];
        cancel(lane);
        const generation = lane.generation;
        let targetCallback;
        let initial = true;

        function runScoped(action) {
            const previous = timerRoot.setTimeout;
            function scopedTimeout(callback, delay, ...timerArgs) {
                if (initial && targetCallback === undefined) targetCallback = callback;
                if (callback !== targetCallback) {
                    return previous.call(timerRoot, callback, delay, ...timerArgs);
                }
                if (typeof callback !== "function") throw new Error("NATIVE_SELECTION_TIMER_INVALID");
                let handle;
                const invoke = function (...receivedArgs) {
                    lane.handles.delete(handle);
                    if (stopped || lane.generation !== generation) return;
                    return runScoped(() => callback.apply(this, receivedArgs));
                };
                handle = previous.call(timerRoot, invoke, delay, ...timerArgs);
                lane.handles.add(handle);
                return handle;
            }
            timerRoot.setTimeout = scopedTimeout;
            try {
                return action();
            } finally {
                timerRoot.setTimeout = previous;
            }
        }

        try {
            return runScoped(() => original.apply(panel, args));
        } catch (error) {
            cancel(lane);
            throw error;
        } finally {
            initial = false;
        }
    }

    function trackedPending(...args) { return capture(this, "pending", originalPending, args); }
    function trackedFocus(...args) { return capture(this, "focus", originalFocus, args); }
    Panel.prototype.selectFirstSettingDeferred = trackedPending;
    Panel.prototype.SelectWidgetToFocus = trackedFocus;

    return {
        clearPendingSelect(panel) {
            // Calling the original public method really clears its previous
            // intent first. Its replacement intent targets no collection, so
            // late native entry-created callbacks cannot select our custom row.
            // No native list, selected item or setting value is changed here.
            const collection = panel.CurrentCollection;
            try {
                panel.CurrentCollection = undefined;
                capture(panel, "pending", originalPending, [false]);
            } finally {
                panel.CurrentCollection = collection;
                cancel(getState(panel).pending);
            }
        },
        cancelSelectWidgetFocusTimer(panel) {
            cancel(getState(panel).focus);
        },
        release(panel) {
            const state = states.get(panel);
            if (!state) return;
            cancel(state.pending);
            cancel(state.focus);
            liveStates.delete(state);
            states.delete(panel);
        },
        stop() {
            if (stopped) return;
            stopped = true;
            for (const state of liveStates) {
                cancel(state.pending);
                cancel(state.focus);
            }
            liveStates.clear();
            if (Panel.prototype.selectFirstSettingDeferred === trackedPending) {
                Panel.prototype.selectFirstSettingDeferred = originalPending;
            }
            if (Panel.prototype.SelectWidgetToFocus === trackedFocus) {
                Panel.prototype.SelectWidgetToFocus = originalFocus;
            }
        }
    };
}

module.exports = { createNativeSelectionLifecycle };
