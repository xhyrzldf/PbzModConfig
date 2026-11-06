-- Selection, details text and JS-style key routing for the native settings page (JS 0.3.13
-- NativeMenu.select/details/key/analog). Pure Lua: the menu supplies polled focus/hover samples,
-- the runtime supplies the actions. Nothing here touches the engine.
local Selection = {}

-- Native tab actions keep Z/C, back and shoulder/trigger input (JS NativeMenu.key).
Selection.PASS_THROUGH = {Z = true, C = true, Escape = true, Gamepad_FaceButton_Right = true,
    Gamepad_LeftShoulder = true, Gamepad_RightShoulder = true, Gamepad_LeftTrigger = true, Gamepad_RightTrigger = true}
Selection.CONFIRM = {Enter = true, SpaceBar = true, Gamepad_FaceButton_Bottom = true}

-- JS selects a row when it gains focus (OnAddedToFocusPath) or when the mouse enters it
-- (OnMouseEnter). Polling sees states, so only transitions select: a newly focused row wins,
-- otherwise a newly hovered one; a pointer resting on a row does not steal selection back after
-- keyboard navigation moved it.
function Selection.tracker()
    local lastFocus, lastHover, selected = nil, nil, nil
    local self = {}
    -- samples: ordered {id, selectable, focused, hovered}; allow(id) may veto (key capture).
    function self.observe(samples, allow)
        local focusId, hoverId
        for _, sample in ipairs(samples) do
            if sample.selectable then
                if sample.focused and not focusId then focusId = sample.id end
                if sample.hovered and not hoverId then hoverId = sample.id end
            end
        end
        local nextId, via
        if focusId and focusId ~= lastFocus then nextId, via = focusId, "focus"
        elseif hoverId and hoverId ~= lastHover then nextId, via = hoverId, "hover" end
        lastFocus, lastHover = focusId, hoverId
        if nextId and nextId ~= selected and (not allow or allow(nextId)) then
            selected = nextId
            return nextId, via
        end
        return nil
    end
    function self.set(id) selected = id end
    function self.selected() return selected end
    function self.reset() lastFocus, lastHover, selected = nil, nil, nil end
    return self
end

-- JS NativeMenu.details(): the right-hand pane for the selected row. A mod title shows the plain
-- name (its version has its own description line) and is the only row with the framework credit.
function Selection.details(model)
    if not model then return {name = "", description = "", disabled = "", warning = "", footer = false} end
    return {
        name = (model.section and (model.title or model.label) or model.label) or "",
        description = model.description or "",
        disabled = model.enabled == false and (model.disabledReason or "") or "",
        warning = model.warning or "",
        footer = model.section == true,
    }
end

-- Ids a keyboard/controller cursor may land on, in display order (headers are skipped,
-- disabled rows stay reachable so their reason can be read).
function Selection.navigable(models)
    local ids = {}
    for _, model in ipairs(models) do
        if model.type ~= "header" and model.visible ~= false then ids[#ids + 1] = model.id end
    end
    return ids
end

function Selection.neighbour(models, id, delta)
    local ids = Selection.navigable(models)
    if #ids == 0 then return nil end
    local index
    for i, value in ipairs(ids) do if value == id then index = i end end
    if not index then return ids[1] end
    return ids[math.max(1, math.min(#ids, index + delta))]
end

-- Optional JS-style navigation consumer (capability navigation = "custom"). `navigation` is a
-- PbzNavigation instance; `actions` = {selected(), move(id, delta), step(id, delta), confirm(id)}.
-- Returns true when the key belongs to the page (JS returned Handled for those).
function Selection.router(navigation, actions)
    local self = {}
    function self.key(name, isRepeat)
        local nav = navigation.key(name)
        if nav then
            if nav.fire then actions[nav.kind](actions.selected(), nav.delta) end
            return true
        end
        if Selection.CONFIRM[name] then
            if not isRepeat then actions.confirm(actions.selected()) end
            return true
        end
        if Selection.PASS_THROUGH[name] then return false end
        return true
    end
    function self.keyUp(name) return navigation.keyUp(name) end
    function self.analog(name, value)
        local nav = navigation.analog(name, value)
        if not nav then return false end
        if nav.fire then actions[nav.kind](actions.selected(), nav.delta) end
        return true
    end
    function self.reset() navigation.reset() end
    return self
end

return Selection
