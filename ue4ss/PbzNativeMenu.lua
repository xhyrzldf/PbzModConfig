-- UE4SS port adapted from the existing native-menu prototype.
--
-- The page is a ScrollBox of cloned native rows (the route verified in the game). JS 0.3.13 hosts
-- the rows in a CommonListView whose row host subclass receives focus/hover callbacks; Lua cannot
-- subclass, so selection is derived by polling read-only widget queries (focus first, then hover),
-- and the details pane, credit footer and focus restore follow from that selection.
local Widgets = require("PbzNativeWidgets")
local Rows = require("PbzNativeRows")

local function optional(name)
    local ok, result = pcall(require, name)
    if ok then return result end
    if tostring(result):find("module '" .. name .. "' not found", 1, true) then return nil end
    error(result, 0)
end
local Selection = optional("PbzNativeSelection")
local Footer = optional("PbzNativeFooter")
local Events = optional("PbzNativeEvents")
local Metadata = optional("PbzModConfigMetadata")

local Menu = {}
local POLL_MS = 100
local DETAIL_FIELDS = {
    {"Text_SettingName", "name"}, {"RichText_Description", "description"},
    {"RichText_DisabledDetails", "disabled"}, {"RichText_WarningDetails", "warning"},
}

local function hasMethod(object, name)
    local ok, method = pcall(function() return object[name] end)
    if not ok then return false end
    return type(method) == "function" or (type(method) == "userdata" and method:IsValid())
end

local function query(widget, name)
    if not Widgets.valid(widget) or not hasMethod(widget, name) then return false end
    return widget[name](widget) == true
end

-- handlers (all optional): preview(model), commit(model), select(model, via), active(bool),
-- allowSelect(id), word(key), styleChoice(rotator, label, locale), launch(url), now(),
-- capabilities = {authorLink, listStyle, coverEvents, selection (default true)}, onCover(), onResume().
function Menu.create(panel, tab, models, onChange, report, handlers)
    handlers = handlers or {}
    local capabilities = handlers.capabilities or {}
    local state = {disposed = false, rows = {}, active = false, models = models, byId = {}, hasDetails = false}
    local list, details, layout, footer, pageEvents
    local tracker = Selection and Selection.tracker() or nil
    local selectionBroken, pendingFocus = capabilities.selection == false, false
    -- Our ScrollBox has its own selection. SettingPanel's IsEnterSecond instead
    -- controls a native Back step (list -> tab bar), which leaves this custom
    -- page visible. Keep focus intent locally and let the native guarded close
    -- handle Back directly while the mod page owns the selection.
    local enteredList = false
    local function releaseListNavigation()
        if enteredList then
            if panel.IsEnterSecond == false then panel.IsEnterSecond = true end
            enteredList = false
        end
    end
    report = report or function(code, detail)
        print("[PbzModConfig] " .. code .. " " .. tostring(detail) .. "\n")
    end
    local function word(key) return handlers.word and handlers.word(key) or key end
    for index, model in ipairs(models) do if model.id ~= nil then state.byId[model.id] = index end end

    -- True once every row, event scope and widget is released. A failed step stays queued and a
    -- later call retries it; the page is inert from the first call on.
    local release = {}
    function state.dispose()
        state.disposed = true
        -- A page that lost its panel or one of its own widgets is forgotten, never released piecemeal;
        -- this holds for every retry too (review round 8).
        local whole = Widgets.valid(panel)
        for _, widget in ipairs({list or false, details or false, layout and layout.root or false,
            layout and layout.detailRoot or false}) do
            if widget and not Widgets.valid(widget) then whole = false end
        end
        if not whole then return state.abandon() end
        -- Runtime.stop first selects a native tab. Hand its navigation back,
        -- but do not restore a second-level flag when the whole menu closes.
        local tabs = panel.W_OverlayTabList_C
        if Widgets.valid(tabs) and tabs:GetSelectedTabId():ToString() ~= tab.id:ToString() then
            releaseListNavigation()
        end
        local clean = true
        if pageEvents then
            local ok, cleared = pcall(pageEvents.dispose)
            if ok and cleared ~= false then pageEvents = nil
            else
                clean = false
                if not ok then report("PAGE_EVENT_RELEASE_FAILED", cleared) end
            end
        end
        if not release.rows then release.rows, state.rows = state.rows, {} end
        for i = #release.rows, 1, -1 do
            local ok, cleared = pcall(release.rows[i].dispose)
            if ok and cleared ~= false then table.remove(release.rows, i)
            else
                clean = false
                if not ok then report("ROW_RELEASE_FAILED", cleared) end
            end
        end
        -- Found dead here as well: the game's details pane is never restored later (review round 7).
        if layout and layout.external and layout.originalDetails ~= nil and not Widgets.valid(layout.originalDetails) then
            layout.originalDetails, state.originalDetailsVisibility = nil, nil
        end
        if layout and layout.external and Widgets.valid(layout.originalDetails)
            and state.originalDetailsVisibility ~= nil then
            local ok, err = pcall(function() layout.originalDetails:SetVisibility(state.originalDetailsVisibility) end)
            if ok then state.originalDetailsVisibility = nil
            else
                clean = false
                report("MENU_RELEASE_FAILED", err)
            end
        end
        if not release.widgets then
            release.widgets = {}
            for _, widget in ipairs({list or false, details or false, layout and layout.root or false,
                layout and layout.detailRoot or false}) do
                if widget then release.widgets[#release.widgets + 1] = widget end
            end
        end
        for i = #release.widgets, 1, -1 do
            local widget = release.widgets[i]
            local ok, err = pcall(function()
                if Widgets.valid(widget) then widget:RemoveFromParent() end
            end)
            if ok then table.remove(release.widgets, i)
            else
                clean = false
                report("MENU_RELEASE_FAILED", err)
            end
        end
        return clean
    end

    -- A native callback or refresh of ours failed: the page fails once (bounded detail), releases
    -- everything it owns and is never touched again (JS NativeMenu.fail). The owner sees `disposed`.
    function state.fail(err, code)
        if state.failed then return end
        state.failed = true
        local detail = tostring(err)
        if #detail > 160 then detail = detail:sub(1, 160) end
        report(code or "MENU_FAILED", detail)
        local ok, released = pcall(state.dispose)
        if not ok or released == false then report("MENU_RETIRE_FAILED", ok and "incomplete release" or released) end
    end

    local function suspended() return type(handlers.suspended) == "function" and handlers.suspended() == true end
    -- Called from inside native callbacks: go inert at once, release on the next game-thread turn
    -- (a hook must not unregister itself while it runs).
    local function fault(err)
        if state.failed then return end
        state.disposed = true
        ExecuteInGameThread(function()
            -- A world change in between forgets the page instead (state.abandon): nothing to release.
            if suspended() then return end
            state.fail(err, "MENU_CALLBACK_FAILED")
        end)
    end

    function state.valid()
        if state.disposed then return false end
        local alive = Widgets.valid(panel) and Widgets.valid(list) and Widgets.valid(details)
            and layout ~= nil and Widgets.valid(layout.root)
            and (layout.detailRoot == nil or Widgets.valid(layout.detailRoot))
        if alive then
            for _, entry in ipairs(state.rows) do if not Widgets.valid(entry.row) then alive = false; break end end
        end
        -- A page that lost a widget is dropped in Lua: releasing it would call into the rest of a
        -- subtree that is no longer known to be whole (review 2026-11-05).
        if not alive then state.abandon(); return false end
        return true
    end

    local function renderDetails()
        if not state.valid() or not state.hasDetails then return end
        local index = state.selectedId and state.byId[state.selectedId] or nil
        local model = index and state.models[index] or nil
        local info = Selection.details(model)
        for _, field in ipairs(DETAIL_FIELDS) do
            local label = details[field[1]]
            if Widgets.valid(label) then
                local value = info[field[2]]
                Widgets.text(label, value)
                label:SetVisibility(value ~= "" and Widgets.V.SelfHitTestInvisible or Widgets.V.Collapsed)
            end
        end
        if footer then footer.update(info.footer) end
        if handlers.select then
            local ok, err = pcall(handlers.select, model, state.lastVia)
            if not ok then report("SELECTION_HANDLER_FAILED", err) end
        end
    end

    -- Programmatic or polled selection: native row highlight and details.
    function state.select(id, via, focus)
        if not state.valid() then return false end
        local index = id and state.byId[id]
        local model = index and state.models[index]
        if not model or model.type == "header" or model.visible == false then return false end
        if handlers.allowSelect and not handlers.allowSelect(id) then return false end
        if state.selectedId ~= id then
            local old = state.selectedId and state.byId[state.selectedId]
            if old and state.rows[old] then state.rows[old].setSelected(false) end
            state.selectedId = id
            if tracker then tracker.set(id) end
            state.rows[index].setSelected(true)
        end
        state.lastVia = via
        if state.active and not state.covered then
            enteredList = true
            panel.IsEnterSecond = false
        end
        renderDetails()
        if focus then state.focus(id) end
        return true
    end

    function state.focus(id)
        if not state.valid() then return false end
        local index = id and state.byId[id]
        if not index or not state.rows[index] then return false end
        local ok, focused = pcall(state.rows[index].focus)
        if not ok then report("FOCUS_FAILED", focused); return false end
        return focused
    end

    function state.refreshDetails() renderDetails() end

    -- A world change took the panel: stop every loop and keep nothing, without touching a widget.
    function state.abandon()
        state.disposed, state.failed = true, true
        enteredList = false
        -- Event routes are revoked in Lua so a late delegate of the old page reaches nothing.
        for _, list in ipairs({state.rows, release.rows or {}}) do
            for _, entry in ipairs(list) do
                if type(entry.discardWorld) == "function" then pcall(entry.discardWorld) end
            end
        end
        if pageEvents and type(pageEvents.discardWorld) == "function" then pcall(pageEvents.discardWorld) end
        state.rows, release.rows, release.widgets = {}, {}, {}
        pageEvents, list, details, layout, footer = nil, nil, nil, nil, nil
        return true
    end

    local ok, err = xpcall(function()
        list = Widgets.native(panel, "ScrollBox")
        list:SetVisibility(Widgets.V.Visible)
        state.host = list -- owner of throw-away native receivers (reset dialog)
        details = Widgets.widget(panel, panel.Details_Settings:GetClass())
        details:SetVisibility(Widgets.V.Collapsed)
        state.details = details
        layout = Widgets.mount(panel, list, details, report)
        state.layout = layout
        if Events and (capabilities.authorLink or capabilities.coverEvents) then
            pageEvents = Events.create(panel, list, report, fault, function() state.abandon() end)
        end
        for index, model in ipairs(models) do
            local entry = Rows.create(panel, list, model, function(value, source)
                if state.disposed or not state.active then return end
                onChange(model, value, source)
            end, {preview = function()
                if state.disposed or not state.active or not handlers.preview then return end
                handlers.preview(model)
            end, commit = function()
                if state.disposed or not handlers.commit then return end
                handlers.commit(model)
            end, styleChoice = handlers.styleChoice, fault = fault, lost = function() state.abandon() end})
            state.rows[index] = entry
        end
        -- Details pane: our own clone of the native details widget (JS state.detailView).
        state.hasDetails = Selection ~= nil and Widgets.valid(details.Text_SettingName)
        if state.hasDetails and Footer and Metadata then
            local buttonClass
            for _, entry in ipairs(state.rows) do if entry.buttonClass then buttonClass = entry.buttonClass; break end end
            local link
            if capabilities.authorLink and pageEvents then
                link = {buttonClass = buttonClass, bindClick = pageEvents.bindClick, launch = handlers.launch or function(url)
                    local library = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
                    assert(Widgets.valid(library), "LAUNCH_LIBRARY_MISSING")
                    library:LaunchURL(url)
                end}
            end
            local built, made = pcall(Footer.create, {details = details, word = word, metadata = Metadata, report = report,
                accepts = function() return state.active and not state.disposed end, now = handlers.now, link = link})
            if built then footer = made else report("NATIVE_FOOTER_FAILED", made) end
        end
        -- A08: optional native list look (scroll bar padding, entry spacing), off until confirmed.
        if capabilities.listStyle then
            local styled, failure = pcall(function()
                local source = panel.ListView_Settings
                local padding = source.ScrollBarPadding
                if padding ~= nil and hasMethod(list, "SetScrollbarPadding") then
                    list:SetScrollbarPadding({Left = padding.Left, Top = padding.Top, Right = padding.Right, Bottom = padding.Bottom})
                end
                local spacing = source.VerticalEntrySpacing
                if type(spacing) == "number" and spacing > 0 then
                    for _, entry in ipairs(state.rows) do
                        local slot = entry.outer and entry.outer.Slot
                        if Widgets.valid(slot) and hasMethod(slot, "SetPadding") then slot:SetPadding({Left = 0, Top = 0, Right = 0, Bottom = spacing}) end
                    end
                end
            end)
            if not styled then report("LIST_STYLE_FAILED", failure) end
        end
        -- J09: a sub-page or dialog over the settings page pauses input (JS bindHost), off until confirmed.
        if capabilities.coverEvents and pageEvents then
            local host = panel.SettingWidget
            if Widgets.valid(host) then
                local bound, failure = pcall(function()
                    pageEvents.bindClick(host.OnHostDeactivated, function()
                        state.covered = true
                        if handlers.onCover then handlers.onCover() end
                    end, host)
                    pageEvents.bindClick(host.OnHostReactivated, function()
                        state.covered = false
                        pendingFocus = true
                        if handlers.onResume then handlers.onResume() end
                    end, host)
                end)
                if not bound then report("COVER_EVENTS_UNAVAILABLE", failure) end
            end
        end
    end, debug.traceback)
    if not ok then
        state.dispose()
        error(err, 0)
    end

    local hoveredIndex = nil
    local function pollSelection()
        if selectionBroken or not tracker or state.covered then return end
        local samples = {}
        hoveredIndex = nil
        local polled, failure = pcall(function()
            for index, model in ipairs(state.models) do
                local entry = state.rows[index]
                local selectable = model.type ~= "header" and model.visible ~= false
                local sample = {id = model.id, selectable = selectable, focused = false, hovered = false}
                if selectable and entry then
                    local row = entry.row
                    sample.focused = query(row, "HasFocusedDescendants")
                        or (model.enabled == false and query(row, "HasAnyUserFocus"))
                    sample.hovered = query(row, "IsHovered")
                    if sample.hovered and not hoveredIndex then hoveredIndex = index end
                end
                samples[#samples + 1] = sample
            end
        end)
        if not polled then
            selectionBroken = true
            report("SELECTION_QUERY_FAILED", failure)
            return
        end
        local id, via = tracker.observe(samples, handlers.allowSelect)
        if id then
            -- Evidence for the in-game check, bounded so hovering cannot flood the log.
            state.selectionLogs = (state.selectionLogs or 0) + 1
            if state.selectionLogs <= 20 then report("SELECTION_CHANGED", id .. " via=" .. tostring(via)) end
            state.select(id, via, false)
        end
    end

    local function focusOnEntry()
        if not pendingFocus or state.covered then return end
        local entered = enteredList
        pcall(function() entered = entered or panel.IsEnterSecond == true end)
        -- J08: while the player is still on the tab row, leave focus there.
        if not entered then return end
        pendingFocus = false
        local target = state.selectedId
        if not target and Selection then target = Selection.navigable(state.models)[1] end
        if target then state.select(target, "enter", true) end
    end

    local function refreshActive()
        if not state.valid() then return end
        local tabList, switcher = panel.W_OverlayTabList_C, panel.WidgetSwitcher_65
        if not Widgets.valid(tabList) or not Widgets.valid(switcher) then state.abandon(); return end
        local active = tabList:GetSelectedTabId():ToString() == tab.id:ToString()
        -- The game's own details pane, found dead once, is never restored later.
        if layout.external and layout.originalDetails ~= nil and not Widgets.valid(layout.originalDetails) then
            layout.originalDetails, state.originalDetailsVisibility = nil, nil
        end
        if active then
            if layout.external and Widgets.valid(layout.originalDetails) then
                if not state.active then
                    state.originalDetailsVisibility = layout.originalDetails:GetVisibility()
                end
                layout.originalDetails:SetVisibility(Widgets.V.Collapsed)
            end
            if not Widgets.valid(switcher:GetActiveWidget())
                or switcher:GetActiveWidget():GetAddress() ~= layout.root:GetAddress() then
                switcher:SetActiveWidget(layout.root)
            end
            if not state.active and state.hasDetails then
                if Widgets.valid(layout.detailRoot) then layout.detailRoot:SetVisibility(Widgets.V.SelfHitTestInvisible) end
                details:SetVisibility(Widgets.V.SelfHitTestInvisible)
                pendingFocus = true
                renderDetails()
            end
        elseif state.active then
            releaseListNavigation()
            if layout.external and Widgets.valid(layout.originalDetails) then
                layout.originalDetails:SetVisibility(state.originalDetailsVisibility)
                state.originalDetailsVisibility = nil
            end
            if state.hasDetails then
                details:SetVisibility(Widgets.V.Collapsed)
                if Widgets.valid(layout.detailRoot) and layout.detailRoot ~= layout.root then
                    layout.detailRoot:SetVisibility(Widgets.V.Collapsed)
                end
            end
        end
        local changed = state.active ~= active
        state.active = active
        if changed and handlers.active then
            local notified, failure = pcall(handlers.active, active)
            if not notified then report("ACTIVE_HANDLER_FAILED", failure) end
        end
        if active then
            pollSelection()
            focusOnEntry()
        end
    end

    function state.update(index, model)
        assert(state.valid(), "MENU_DISPOSED")
        assert(state.rows[index], "ROW_MISSING")
        state.models[index] = model
        state.rows[index].update(model)
        if model.id == state.selectedId then renderDetails() end
    end

    function state.selectedModel()
        local index = state.selectedId and state.byId[state.selectedId]
        return index and state.models[index] or nil
    end

    -- The row under the mouse right now (a click swallowed by the key capture widget is resolved here).
    function state.hoveredModel()
        if not state.valid() then return nil end
        local entry = hoveredIndex and state.rows[hoveredIndex]
        if entry and query(entry.row, "IsHovered") then return state.models[hoveredIndex] end
        for index, candidate in ipairs(state.rows) do
            if query(candidate.row, "IsHovered") then hoveredIndex = index; return state.models[index] end
        end
        return nil
    end

    -- The selection follows the mouse every frame, not every POLL_MS: at 100 ms the highlight lagged
    -- and moved in steps while sliding over the rows (2026-11-05). Only a moved mouse is looked at; a
    -- row that is still hovered costs one query, a full pass runs when it is left.
    local layoutLibrary, lastMouse = nil, nil
    local function followMouse()
        if state.disposed or not state.active or state.covered or selectionBroken or not tracker then lastMouse = nil; return end
        if not Widgets.valid(layoutLibrary) then
            local find = rawget(_G, "StaticFindObject")
            layoutLibrary = find and find("/Script/UMG.Default__WidgetLayoutLibrary") or nil
        end
        if not Widgets.valid(panel) then state.abandon(); return end
        if not Widgets.valid(layoutLibrary) then return end
        local read, position = pcall(function() return layoutLibrary:GetMousePositionOnViewport(panel) end)
        if not read or type(position) ~= "table" and type(position) ~= "userdata" then return end
        local x, y = tonumber(position.X), tonumber(position.Y)
        if not x or not y then return end
        local moved = lastMouse == nil or lastMouse[1] ~= x or lastMouse[2] ~= y
        lastMouse = {x, y}
        if not moved then return end
        -- A dead row drops the page in Lua; the hover loops never call a row that died.
        for _, candidate in ipairs(state.rows) do
            if not Widgets.valid(candidate.row) then state.abandon(); return end
        end
        local entry = hoveredIndex and state.rows[hoveredIndex]
        if entry and query(entry.row, "IsHovered") then return end
        pollSelection()
    end
    local frames = rawget(_G, "ExecuteInGameThreadAfterFrames")
    local function everyFrame()
        if state.disposed then return end
        if suspended() then lastMouse = nil; frames(1, everyFrame); return end
        local ok, err = pcall(followMouse)
        if not ok then report("SELECTION_FOLLOW_FAILED", tostring(err)); return end
        frames(1, everyFrame)
    end
    local function schedule()
        if state.disposed then return end
        if suspended() then ExecuteInGameThreadWithDelay(POLL_MS, schedule); return end
        ExecuteInGameThread(function()
            -- Queued before a world change, run during it: checked again here (review 2026-11-05).
            if state.disposed then return end
            if suspended() then ExecuteInGameThreadWithDelay(POLL_MS, schedule); return end
            local refreshed, refreshError = xpcall(refreshActive, debug.traceback)
            if not refreshed then
                state.fail(refreshError, "MENU_REFRESH_FAILED")
                return
            end
            if not state.disposed then ExecuteInGameThreadWithDelay(POLL_MS, schedule) end
        end)
    end

    local refreshed, refreshError = xpcall(refreshActive, debug.traceback)
    if not refreshed then
        state.dispose()
        error(refreshError, 0)
    end
    ExecuteInGameThreadWithDelay(POLL_MS, schedule)
    if type(frames) == "function" then frames(1, everyFrame) end
    return state
end

return Menu
