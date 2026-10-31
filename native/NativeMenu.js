"use strict";
const { createSupport } = require("./NativeSupport");
const { createRows } = require("./NativeRows");
const { createFooter } = require("./NativeFooter");
const { createIconLoader } = require("./NativeIcon");
const { resolve, language } = require("../src/Localization");
const { words: WORDS } = require("../src/LocaleStrings");
const TAB = "PbzModConfig";
function createMenu(UE, puerts, framework, report) {
    const ui = createSupport(UE, report), states = new Map(), tokenOwners = new Map();
    const expanded = new Map(), loadIcon = createIconLoader(UE, ui, report);
    let rowFactory;
    function create(panel) {
        if (states.has(panel)) return states.get(panel);
        if (!rowFactory) rowFactory = createRows(UE, puerts, ui, tokenOwners, report);
        const state = {
            panel, scope: ui.lifetime(), hostScope: null, disposed: false, active: false, covered: false,
            confirming: false, entries: new Map(), models: new Map(), byId: new Map(), owners: new Map(),
            selected: null, pendingFocus: null, entriesGenerated: false, refreshTimer: null, locale: "en",
            word: name => resolve(WORDS[name], state.locale),
            acceptsInput: () => !state.disposed && state.active && !state.covered && !state.confirming,
            flush: () => framework.flushAll(),
            queueRefresh() {
                if (state.disposed || state.refreshTimer !== null) return;
                state.refreshTimer = setTimeout(() => {
                    state.refreshTimer = null;
                    if (!state.disposed) protect(state, () => state.refresh());
                }, 0);
            },
            refresh() {
                state.locale = language(UE.KismetInternationalizationLibrary.GetCurrentLanguage());
                framework.setLanguage(state.locale);
                const pages = framework.pages(), rows = [];
                const owners = new Map();
                for (const page of pages) {
                    owners.set(page.handle.modId, page.handle.ownerToken);
                    const open = expanded.get(page.handle.modId) === true;
                    const label = page.title + (page.modVersion ? "  ·  " + page.modVersion : "");
                    rows.push({ id: page.handle.modId + "/@title", type: "action", section: true, expanded: open, label, page,
                        description: page.modVersion ? state.word("version") + " " + page.modVersion : "",
                        buttonLabel: state.word(open ? "collapse" : "expand"), enabled: true });
                    if (!open) continue;
                    if (page.error) {
                        rows.push({ id: page.handle.modId + "/@error", type: "header", label: state.word("unavailable"), page });
                        continue;
                    }
                    for (const row of page.rows) {
                        const model = { ...row, page };
                        if (row.type === "toggle") model.options = [{ value: false, label: state.word("off") }, { value: true, label: state.word("on") }];
                        rows.push(model);
                    }
                    rows.push({ id: page.handle.modId + "/@reset", type: "action", label: state.word("reset"), description: page.title,
                        buttonLabel: state.word("reset"), enabled: true, reset: true, page });
                }
                if (!rows.length) rows.push({ id: "@empty", type: "header", label: state.word("empty") });
                const signature = JSON.stringify(rows.map(row => [row.id, row.type, row.options?.map(o => o.value)]));
                const sameOwners = owners.size === state.owners.size && [...owners].every(([id, token]) => state.owners.get(id) === token);
                if (signature !== state.signature || !sameOwners) {
                    rowFactory.releaseState(state);
                    for (const token of state.models.keys()) tokenOwners.delete(token);
                    state.models.clear(); state.byId.clear(); state.entriesGenerated = false;
                    const items = UE.NewArray(UE.Object);
                    for (const row of rows) {
                        // GameSetting is only a native list identity; no dynamic getter/setter is installed.
                        const token = UE.NewObject(UE.GameSettingCollection.StaticClass(), panel);
                        state.models.set(token, row); state.byId.set(row.id, token); tokenOwners.set(token, state); items.Add(token);
                    }
                    state.signature = signature; state.owners = owners;
                    state.pendingFocus = state.selected && state.byId.has(state.selected) ? state.selected : rows.find(r => r.type !== "header")?.id;
                    state.list.BP_SetListItems(items);
                    state.list.RequestRefresh();
                } else {
                    for (const row of rows) {
                        const token = state.byId.get(row.id); state.models.set(token, row);
                        const entry = state.entries.get(row.id);
                        if (entry) try { entry.refresh(row); } catch (e) { report({ code: "ROW_UPDATE_FAILED", id: row.id, detail: String(e) }); }
                    }
                }
                state.styleTab(); state.details();
            },
            styleTab() {
                const button = state.tabs.GetTabButtonBaseByID(TAB);
                if (!button) return;
                const label = state.word("tab");
                if (state.styledButton !== button || state.styledLabel !== label) {
                    for (let i = 0; i < state.tabs.PreregisteredTabInfoArray.Num(); i++) {
                        const descriptor = state.tabs.PreregisteredTabInfoArray.GetRef(i);
                        if (String(descriptor.TabId) !== TAB) continue;
                        // PBZLocText.ValueCache is FText. Let the original blueprint apply
                        // its icon, tint, label and selected-state treatment together.
                        descriptor.TabText.ValueCache = ui.asText(label);
                        button.SetTabLabelInfo(descriptor, false);
                    }
                    button.SetVisibility(ui.V.Visible);
                    state.styledButton = button; state.styledLabel = label;
                }
                state.spaceTab(button);
                if (state.active) ui.text(panel.W_SecondTabLine?.LineText, label);
            },
            spaceTab(button) {
                const box = state.tabs.TabButtonBox, native = state.tabs.TabButtonPadding;
                if (!ui.valid(box) || button.GetParent() !== box) throw new Error("NATIVE_TAB_LAYOUT_MISMATCH");
                let previous = null, found = false, following = false;
                for (let i = 0; i < box.GetChildrenCount(); i++) {
                    const child = box.GetChildAt(i);
                    if (child === button) { found = true; continue; }
                    if (child.GetVisibility() === ui.V.Collapsed) continue;
                    if (found) { following = true; break; }
                    previous = child;
                }
                if (!found) throw new Error("MOD_TAB_LAYOUT_MISSING");
                // Native UpdateTabStyles removes the final tab's right padding. Appending
                // our tab leaves that earlier slot unchanged. Supply only its missing gap
                // on our own slot, so rebuilding native tabs cannot double the spacing.
                const previousRight = previous ? previous.Slot.Padding.Right : 0;
                const margin = new UE.Margin();
                margin.Left = native.Left + (previous ? Math.max(0, native.Right - previousRight) : 0);
                margin.Top = native.Top; margin.Bottom = native.Bottom;
                margin.Right = following ? native.Right : 0;
                const slot = button.Slot, current = slot.Padding;
                if (["Left", "Top", "Right", "Bottom"].some(edge => current[edge] !== margin[edge])) slot.SetPadding(margin);
                const signature = [native.Left, native.Right, previousRight, margin.Left, margin.Right].join(",");
                if (state.spacingSignature !== signature) {
                    state.spacingSignature = signature;
                    report({ code: "TAB_SPACING_APPLIED", nativeLeft: native.Left, nativeRight: native.Right,
                        previousRight, left: margin.Left, right: margin.Right });
                }
            },
            details() {
                const m = state.models.get(state.byId.get(state.selected));
                const view = state.detailView;
                if (!view) return;
                for (const [field, value] of [
                    ["Text_SettingName", (m?.section ? m.page.title : m?.label) || ""], ["RichText_Description", m?.description || ""],
                    ["RichText_DisabledDetails", m?.enabled === false ? m.disabledReason : ""],
                    ["RichText_WarningDetails", m?.page?.persistence?.state === "failed" ? state.word("failed") : m?.page?.persistence?.state === "pending" ? state.word("pending") : ""],
                ]) {
                    if (!ui.valid(view[field])) continue;
                    ui.text(view[field], value); view[field].SetVisibility(value ? ui.V.SelfHitTestInvisible : ui.V.Collapsed);
                }
                state.footer?.update(m?.section === true);
            },
            select(id, focus) {
                const token = state.byId.get(id), m = state.models.get(token);
                if (!m || m.type === "header" || !state.acceptsInput()) return;
                if (state.selected !== id) {
                    const old = state.entries.get(state.selected);
                    if (old && ui.valid(old.row)) old.row.SetSelected(false);
                    state.selected = id; state.list.BP_SetSelectedItem(token);
                }
                const entry = state.entries.get(id);
                if (entry) entry.row.SetSelected(true);
                state.details(); panel.IsEnterSecond = true;
                if (focus) { state.pendingFocus = id; state.list.BP_ScrollItemIntoView(token); state.focusReady(); }
            },
            rowReady(entry) {
                if (state.selected === entry.id) entry.row.SetSelected(true);
                // OnListItemObjectSet can run before Slate constructs the row. EntriesGenerated is the gate.
            },
            focusReady() {
                if (!state.acceptsInput() || !state.entriesGenerated || !state.pendingFocus) return;
                const id = state.pendingFocus, entry = state.entries.get(id);
                if (!entry || !ui.valid(entry.host) || state.models.get(entry.item)?.id !== id) return;
                state.pendingFocus = null; state.select(id, false);
                const model = state.models.get(entry.item);
                (model.enabled !== false && entry.control ? entry.control : entry.host).SetFocus();
            },
            edit(id, value) {
                const m = state.models.get(state.byId.get(id));
                if (!state.acceptsInput() || !m || m.enabled === false) return;
                state.select(id, false);
                const result = framework.edit(m.page.handle, m.key, value, m.page.revision);
                if (!result.ok) report({ code: "EDIT_REJECTED", id, error: result.error });
                // Re-read the owner immediately; a second input cannot reuse the previous revision.
                state.refresh();
            },
            step(id, delta) {
                const m = state.models.get(state.byId.get(id));
                if (!m || m.enabled === false) return;
                if (m.section) {
                    if ((expanded.get(m.page.handle.modId) === true) !== (delta > 0)) state.action(id);
                    return;
                }
                if (m.type === "number") {
                    const tick = Math.round((m.value - m.min) / m.step) + delta;
                    state.edit(id, Number(Math.max(m.min, Math.min(m.max, m.min + tick * m.step)).toFixed(10)));
                } else if (m.options?.length) {
                    const index = m.options.findIndex(o => o.value === m.value);
                    state.edit(id, m.options[(index + delta + m.options.length) % m.options.length].value);
                }
            },
            action(id) {
                const m = state.models.get(state.byId.get(id));
                if (!m || m.enabled === false || !state.acceptsInput()) return;
                state.select(id, false);
                if (m.section) {
                    expanded.set(m.page.handle.modId, expanded.get(m.page.handle.modId) !== true);
                    state.pendingFocus = id; state.queueRefresh();
                    return;
                }
                if (m.reset) {
                    state.confirming = true; state.pendingFocus = id;
                    const handle = m.page.handle;
                    const action = UE.AsyncAction_ShowConfirmation.ShowConfirmationYesNo(panel, undefined, ui.asText(state.word("confirm")));
                    if (!action) { state.confirming = false; throw new Error("RESET_DIALOG_UNAVAILABLE"); }
                    const scope = ui.lifetime(); state.scope.own(() => scope.dispose());
                    scope.bind(action.OnResult, result => {
                        scope.dispose(); state.confirming = false;
                        if (state.disposed) return;
                        if (result === UE.ECommonMessagingResult.Confirmed) {
                            const latest = framework.pages().find(p => p.handle.modId === handle.modId && p.handle.ownerToken === handle.ownerToken);
                            if (latest) framework.reset(handle, undefined, latest.revision);
                            state.flush();
                        }
                        state.refresh(); state.focusReady();
                    });
                    action.Activate();
                } else {
                    const result = framework.action(m.page.handle, m.key, m.page.revision);
                    if (!result.ok) report({ code: "ACTION_FAILED", id, error: result.error });
                    state.refresh();
                }
            },
            move(id, delta) {
                const ids = [...state.byId.keys()].filter(key => state.models.get(state.byId.get(key)).type !== "header");
                const index = ids.indexOf(id), target = ids[Math.max(0, Math.min(ids.length - 1, index + delta))];
                if (target) state.select(target, true);
            },
            key(id, name, repeat) {
                if (["Up", "W", "Gamepad_DPad_Up", "Gamepad_LeftStick_Up"].includes(name)) state.move(id, -1);
                else if (["Down", "S", "Gamepad_DPad_Down", "Gamepad_LeftStick_Down"].includes(name)) state.move(id, 1);
                else if (["Left", "A", "Gamepad_DPad_Left", "Gamepad_LeftStick_Left"].includes(name)) state.step(id, -1);
                else if (["Right", "D", "Gamepad_DPad_Right", "Gamepad_LeftStick_Right"].includes(name)) state.step(id, 1);
                else if (["Enter", "SpaceBar", "Gamepad_FaceButton_Bottom"].includes(name)) {
                    if (!repeat) { const m = state.models.get(state.byId.get(id)); if (m?.type === "action") state.action(id); else state.step(id, 1); }
                } else if (["Z", "C", "Escape", "Gamepad_FaceButton_Right", "Gamepad_LeftShoulder", "Gamepad_RightShoulder",
                    "Gamepad_LeftTrigger", "Gamepad_RightTrigger"].includes(name)) return false;
                // Native tab actions retain ownership of Z/C and shoulder/trigger input, including repeats.
                // Other keys stay in this native settings page, including business mod hotkeys.
                return true;
            },
            analog(id, name, value) {
                if (name !== "Gamepad_LeftX" && name !== "Gamepad_LeftY") return false;
                if (Math.abs(value) < 0.5) { state.heldAxis = null; return true; }
                const direction = name + Math.sign(value), now = Date.now();
                if (state.heldAxis !== direction || now - state.lastAxisTime > 220) {
                    state.heldAxis = direction; state.lastAxisTime = now;
                    if (name === "Gamepad_LeftY") state.move(id, value > 0 ? -1 : 1); else state.step(id, value > 0 ? 1 : -1);
                }
                return true;
            },
            bindHost() {
                state.hostScope?.dispose(); state.hostScope = ui.lifetime();
                const host = panel.SettingWidget;
                state.hostScope.bind(host.OnHostDeactivated, () => state.cover());
                state.hostScope.bind(host.OnHostReactivated, () => state.resume());
            },
            cover() { state.covered = true; state.pendingFocus = state.selected || state.pendingFocus; state.flush(); },
            resume() {
                if (state.disposed) return;
                state.covered = false;
                if (panel.CurrentCollection === state.collection) state.show();
            },
            show() {
                if (state.disposed) return;
                state.active = true; state.refresh();
                panel.WidgetSwitcher_65.SetActiveWidget(state.layout.root);
                state.layout.detailRoot.SetVisibility(ui.V.SelfHitTestInvisible);
                if (state.layout.external) {
                    if (state.detailsVisibility === undefined) state.detailsVisibility = state.layout.originalDetails.GetVisibility();
                    state.layout.originalDetails.SetVisibility(ui.V.Collapsed);
                }
                panel.IsEnterSecond = true;
                state.pendingFocus = state.selected || state.pendingFocus || [...state.byId.keys()].find(id => state.models.get(state.byId.get(id)).type !== "header");
                state.focusReady();
            },
            hide() {
                state.active = false; state.pendingFocus = null; state.flush();
                if (state.layout) {
                    state.layout.detailRoot.SetVisibility(ui.V.Collapsed);
                    if (state.detailsVisibility !== undefined && ui.valid(state.layout.originalDetails)) {
                        state.layout.originalDetails.SetVisibility(state.detailsVisibility); state.detailsVisibility = undefined;
                    }
                }
            },
            dispose() {
                if (state.disposed) return;
                state.hide(); state.disposed = true;
                if (state.refreshTimer !== null) clearTimeout(state.refreshTimer);
                state.hostScope?.dispose(); state.scope.dispose(); rowFactory.releaseState(state);
                for (const token of state.models.keys()) tokenOwners.delete(token);
                state.models.clear(); state.byId.clear(); state.entries.clear();
                if (ui.valid(state.tabs)) {
                    if (state.ownsTab || (state.tabRegistrationStarted && state.tabs.GetTabButtonBaseByID(TAB))) state.tabs.RemoveTab(TAB);
                    for (const name of ["TabButtonIDs", "PreregisteredTabInfoArray"]) {
                        if (!(name === "TabButtonIDs" ? state.ownsNavigation : state.ownsDescriptor)) continue;
                        const array = state.tabs[name];
                        if (!array) continue;
                        for (let i = array.Num() - 1; i >= 0; i--) {
                            if (String(name === "TabButtonIDs" ? array.Get(i) : array.Get(i).TabId) === TAB) array.RemoveAt(i);
                        }
                    }
                    state.tabs.ResetTabSwitchTracking();
                }
                if (panel.SettingCollections && state.collection) {
                    for (let i = panel.SettingCollections.Num() - 1; i >= 0; i--) if (panel.SettingCollections.Get(i) === state.collection) panel.SettingCollections.RemoveAt(i);
                }
                if (state.layout) {
                    if (panel.WidgetSwitcher_65.GetActiveWidget() === state.layout.root) panel.WidgetSwitcher_65.SetActiveWidgetIndex(0);
                    state.layout.detailRoot.RemoveFromParent(); state.layout.root.RemoveFromParent();
                }
                states.delete(panel);
            }
        };
        states.set(panel, state);
        try {
            state.tabs = panel.W_OverlayTabList_C;
            if (state.tabs.GetTabButtonBaseByID(TAB)) throw new Error("MOD_TAB_ALREADY_OWNED");
            for (const name of ["TabButtonIDs", "PreregisteredTabInfoArray"]) {
                const array = state.tabs[name];
                for (let i = 0; i < array.Num(); i++) if (String(name === "TabButtonIDs" ? array.Get(i) : array.Get(i).TabId) === TAB) throw new Error("MOD_TAB_METADATA_ALREADY_OWNED");
            }
            const collectionCount = panel.SettingCollections.Num();
            if (state.tabs.TabButtonIDs.Num() !== collectionCount) throw new Error("NATIVE_TAB_COLLECTION_MISMATCH");
            state.list = ui.native(panel, "CommonListView");
            state.list.EntryWidgetClass = rowFactory.entryClass;
            state.list.SelectionMode = panel.ListView_Settings.SelectionMode;
            state.list.SetVisibility(ui.V.Visible);
            // Both classes derive from ListViewBase: retain the actual game's scrolling styles.
            for (const name of ["ScrollBarStyle", "ScrollBarPadding", "HorizontalEntrySpacing", "VerticalEntrySpacing"]) if (panel.ListView_Settings[name] !== undefined) state.list[name] = panel.ListView_Settings[name];
            state.detailView = ui.widget(panel, panel.Details_Settings.GetClass());
            state.footer = createFooter(UE, ui, state, report);
            state.layout = ui.mount(panel, state.list, state.detailView);
            state.layout.detailRoot.SetVisibility(ui.V.Collapsed);
            state.scope.bind(state.list.BP_OnEntriesGenerated, () => { state.entriesGenerated = true; state.focusReady(); });
            state.scope.bind(state.list.BP_OnEntryReleased, widget => rowFactory.release(widget));
            state.scope.bind(state.list.BP_OnItemSelectionChanged, item => {
                const model = state.models.get(item); if (model) state.select(model.id, false);
            });
            state.scope.bind(state.list.BP_OnItemScrolledIntoView, () => { state.entriesGenerated = true; state.focusReady(); });
            state.scope.own(framework.subscribe(() => state.queueRefresh()));
            // Observe game language while the panel exists. This never reloads config.
            const languageTimer = setInterval(() => protect(state, () => {
                if (state.disposed) return;
                if (!ui.valid(panel)) { state.dispose(); return; }
                const current = language(UE.KismetInternationalizationLibrary.GetCurrentLanguage());
                if (current !== state.locale) state.queueRefresh();
            }), 500);
            state.scope.own(() => clearInterval(languageTimer));
            state.collection = UE.NewObject(UE.GameSettingCollection.StaticClass(), panel);
            panel.SettingCollections.Add(state.collection);
            const buttonClass = state.tabs.GetTabButtonBaseByID(state.tabs.GetTabIdAtIndex(0)).GetClass();
            const descriptor = new UE.PBZTabDescriptor();
            descriptor.TabId = TAB; descriptor.bHidden = false; descriptor.TabButtonType = buttonClass; descriptor.TabText.ValueCache = ui.asText(state.word("tab"));
            const nativeStyle = state.tabs.PreregisteredTabInfoArray.Get(0);
            const icon = loadIcon(panel);
            if (!ui.valid(icon)) throw new Error("MOD_TAB_ICON_MISSING");
            descriptor.IconBrush = nativeStyle.IconBrush;
            descriptor.IconBrush.ResourceObject = icon;
            descriptor.SwitchSound = nativeStyle.SwitchSound;
            state.tabs.PreregisteredTabInfoArray.Add(descriptor);
            state.ownsDescriptor = true;
            state.tabs.TabButtonIDs.Add(TAB);
            state.ownsNavigation = true;
            state.tabRegistrationStarted = true;
            const registered = state.tabs.RegisterTab(TAB, buttonClass, undefined, collectionCount);
            state.ownsTab = !!state.tabs.GetTabButtonBaseByID(TAB);
            if (registered === false || !state.ownsTab || state.tabs.GetIndexByID(TAB) !== collectionCount) throw new Error("MOD_TAB_PAIRING_FAILED");
            state.tabs.ResetTabSwitchTracking();
            state.bindHost(); state.refresh();
            report({ code: "MOD_MENU_READY", providers: framework.pages().length, route: "native-row-adapter" });
            return state;
        } catch (e) {
            try { state.dispose(); } catch (cleanup) { report({ code: "MENU_ROLLBACK_FAILED", detail: String(cleanup) }); }
            throw e;
        }
    }
    function protect(state, callback) {
        try { return callback(); } catch (e) { report({ code: "MENU_FAILED", detail: String(e) }); }
    }
    return { states, create, get: panel => states.get(panel), protect };
}
module.exports = { createMenu, TAB };
