-- The settings footer's "R 重置本页设置" on the mod page. The game's script rebuilds the footer for each
-- tab and leaves this entry out on ours; the native action bar (W_Systembase_C.WB_PBZTriggerBoundAction
-- .ActionBar, a PBZActionBar) takes it back by row name from DT_PBZUniversalActions, builds it on the next
-- frame in the native place (before "Esc 返回") and shows the key of the current input device itself.
--
--   local bar = ActionBar.create({report = fn})
--   bar.sync(panel)   -- while the mod page is in front: adds the entry when the footer lacks it
--   bar.hovered()     -- true while the mouse is over the entry (a click on it resets, as R does)
local ActionBar = {ROW = "RestoreToDefault", HOST = "W_Systembase_C", RETRY_SECONDS = 0.3}

local function try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
end

local function valid(object)
    return object ~= nil and try(function() return object:IsValid() end) == true
end

local function className(object)
    return try(function() return object:GetClass():GetFName():ToString() end)
end

-- The footer belongs to the system menu that holds the settings panel: walk the panel's outers up to it.
function ActionBar.find(panel)
    local cursor = panel
    for _ = 1, 8 do
        if not valid(cursor) then return nil end
        if className(cursor) == ActionBar.HOST then
            local wrapper = try(function() return cursor.WB_PBZTriggerBoundAction end)
            local bar = valid(wrapper) and try(function() return wrapper.ActionBar end) or nil
            return valid(bar) and bar or nil
        end
        cursor = try(function() return cursor:GetOuter() end)
    end
    return nil
end

local function entryOf(bar, row)
    local entries = bar:GetAllEntries()
    for index = 1, #entries do
        local item = entries[index]
        local entry = try(function() return item:get() end) or item
        if valid(entry) and try(function() return entry.InputActionRowName:ToString() end) == row then return entry end
    end
    return nil
end

-- options: report(code, detail), now() -> seconds, find(panel) -> bar|nil, name(text) -> FName
function ActionBar.create(options)
    options = options or {}
    local now = options.now or os.clock
    local find = options.find or ActionBar.find
    local name = options.name or function(text) return FName(text) end
    local function report(code, detail)
        if options.report then pcall(options.report, code, tostring(detail or "")) end
    end
    local self = {}
    local bar, owner, entry, askedAt, broken = nil, nil, nil, nil, false

    function self.sync(panel)
        if broken then return false end
        local ok, err = pcall(function()
            if owner ~= panel or not valid(bar) then bar, owner, entry, askedAt = find(panel), panel, nil, nil end
            if not bar then return end
            entry = entryOf(bar, ActionBar.ROW)
            if entry then askedAt = nil; return end
            if askedAt and now() - askedAt < ActionBar.RETRY_SECONDS then return end
            bar:AddActionWidget(name(ActionBar.ROW))
            askedAt = now()
        end)
        if not ok then
            broken = true -- one report, then the footer is left alone for this page
            report("ACTION_BAR_FAILED", err)
            return false
        end
        return entry ~= nil
    end

    function self.hovered()
        if entry ~= nil and not valid(entry) then entry = nil end -- found dead: forgotten, re-found by sync()
        return entry ~= nil and try(function() return entry:IsHovered() end) == true
    end

    function self.dispose() bar, owner, entry = nil, nil, nil end
    return self
end

return ActionBar
