-- Basic projection of a provider for a menu that cannot show every control type (port of
-- provider/Compatibility.js, ModConfig 0.3.13). The provider keeps owning every value; the menu only
-- gets the controls it understands:
--   * entries of an unsupported type are left out, and so (recursively) are entries whose
--     enabledWhen/visibleWhen refer to a left-out entry;
--   * read/subscribe/apply/flush/invokeAction results only carry the values of the shown entries;
--   * apply rejects keys the menu does not know (UNKNOWN_KEY);
--   * reset restores the shown entries only, so values the menu cannot show are never cleared;
--   * a plain header tells the player that more settings need a newer ModConfig;
--   * getExtendedDescriptor(1) returns the full provider for a newer menu.
local Projection = {}

local BASE_VALUES = {toggle = true, number = true, choice = true}
Projection.EXTENDED = {keybind = true, color = true, sound = true}
Projection.HEADER_KEY = "modconfig.extensions"
Projection.HINT = {en = "Additional controls require ModConfig 0.3.0 or newer", zhHans = "更多设置需要 ModConfig 0.3.0 或更新版本"}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

-- supported: set of entry types the menu can show. Defaults to the base controls (what a 0.2.x menu showed).
function Projection.needed(provider, supported)
    supported = supported or {header = true, action = true, toggle = true, number = true, choice = true}
    if type(provider) ~= "table" or type(provider.entries) ~= "table" then return false end
    for _, entry in ipairs(provider.entries) do
        if Projection.EXTENDED[entry.type] and not supported[entry.type] then return true end
    end
    return false
end

function Projection.project(provider, supported)
    supported = supported or {header = true, action = true, toggle = true, number = true, choice = true}
    if not Projection.needed(provider, supported) then return provider end
    local omitted = {}
    for _, entry in ipairs(provider.entries) do
        if Projection.EXTENDED[entry.type] and not supported[entry.type] then omitted[entry.key] = true end
    end
    local changed
    repeat
        changed = false
        for _, entry in ipairs(provider.entries) do
            if not omitted[entry.key] then
                for _, rule in ipairs({entry.enabledWhen or false, entry.visibleWhen or false}) do
                    if rule and omitted[rule.key] then omitted[entry.key] = true; changed = true; break end
                end
            end
        end
    until not changed
    local entries, keys = {}, {}
    for _, entry in ipairs(provider.entries) do
        if not omitted[entry.key] then
            entries[#entries + 1] = entry
            if BASE_VALUES[entry.type] or (supported[entry.type] and Projection.EXTENDED[entry.type]) then keys[entry.key] = true end
        end
    end
    local function project(snapshot)
        if type(snapshot) ~= "table" then return snapshot end
        local result = {}
        for key, value in pairs(snapshot) do result[key] = value end
        local values = {}
        for key, value in pairs(snapshot.values or {}) do if keys[key] then values[key] = value end end
        result.values = values
        return result
    end
    local legacy = {}
    for key, value in pairs(provider) do legacy[key] = value end
    function legacy.getExtendedDescriptor(version)
        if version == 1 then return provider end
        return nil
    end
    function legacy.read() return project(provider.read()) end
    function legacy.apply(patch, context)
        local valid = type(patch) == "table" and getmetatable(patch) == nil
        if valid then for key in pairs(patch) do if not keys[key] then valid = false end end end
        if not valid then
            local result = project(provider.read())
            result.ok, result.error = false, "UNKNOWN_KEY"
            return result
        end
        return project(provider.apply(patch, context))
    end
    if type(provider.subscribe) == "function" then
        function legacy.subscribe(listener)
            return provider.subscribe(function(event) return listener(project(event)) end)
        end
    end
    function legacy.reset(groupId, context)
        if groupId ~= nil then
            local known = false
            for _, group in ipairs(provider.groups or {}) do if group.id == groupId then known = true end end
            if not known then
                local result = project(provider.read())
                result.ok, result.error = false, "UNKNOWN_GROUP"
                return result
            end
        end
        local patch = {}
        for _, entry in ipairs(entries) do
            if keys[entry.key] and (groupId == nil or entry.group == groupId) then patch[entry.key] = entry.defaultValue end
        end
        local forwarded = {}
        for key, value in pairs(context or {}) do forwarded[key] = value end
        forwarded.origin = (context and context.origin) or "reset"
        return project(provider.apply(patch, forwarded))
    end
    function legacy.flush() return project(provider.flush()) end
    if type(provider.invokeAction) == "function" then
        function legacy.invokeAction(key, context) return project(provider.invokeAction(key, context)) end
    end
    local headerKey = Projection.HEADER_KEY
    local function taken(candidate)
        for _, entry in ipairs(provider.entries) do if entry.key == candidate then return true end end
        return false
    end
    while taken(headerKey) do headerKey = headerKey .. "_" end
    local shown = {}
    for index, entry in ipairs(entries) do shown[index] = entry end
    shown[#shown + 1] = {key = headerKey, type = "header", label = copy(Projection.HINT)}
    legacy.entries = shown
    return legacy
end

return Projection
