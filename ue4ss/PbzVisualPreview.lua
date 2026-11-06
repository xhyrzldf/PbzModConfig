-- Business-owned appearance previews (ModConfig 0.3.6/0.3.7 createVisualPreview), ported from
-- src/Framework.js hasVisual/openVisual/stopVisual. The framework only owns the lifetime and the
-- copied snapshot; the provider draws into the host it is given. Nothing here calls apply.
--
--   local visual = Visual.create({report = log, locale = function() return "zhHans" end})
--   visual.has(record, key)                 -- record = {provider = ..., snapshot = ...}
--   local opened = visual.open(record, context)   -- {ok, error?, update(key, draft), dispose()}
--   visual.update(key, draft)               -- same as opened.update, for the current preview
--   visual.stop(); visual.dispose()
--
-- Cross-mod proxies (provider.async == true) cannot preview: widgets and functions do not cross
-- UE4SS Lua states.
local Core = require("PbzConfigCore")

local Visual = {}

local function copy(values)
    local result = {}
    for key, value in pairs(values) do result[key] = value end
    return result
end

local function validSnapshot(value)
    return type(value) == "table" and type(value.values) == "table" and math.type(value.revision) == "integer"
        and value.revision >= 0
end

function Visual.create(options)
    options = options or {}
    local report = options.report or function() end
    local function log(code, detail) pcall(report, code, detail) end
    local locale = options.locale or function() return "zhHans" end
    -- Per-provider facts, computed once: value entries and the preview key set (nil = every value key).
    local facts = setmetatable({}, {__mode = "k"})
    local visual, generation, disposed = nil, 0, false

    local function factsOf(provider)
        local known = facts[provider]
        if known then return known end
        known = {values = {}, previewKeys = nil}
        for _, entry in ipairs(type(provider.entries) == "table" and provider.entries or {}) do
            if type(entry) == "table" and type(entry.key) == "string" and Core.VALUE_TYPES[entry.type] then
                known.values[entry.key] = entry
            end
        end
        local keys = provider.visualPreviewKeys
        if keys ~= nil then
            local valid = Core.json.isArray(keys)
            if valid then
                for _, key in ipairs(keys) do
                    if type(key) ~= "string" or not known.values[key] then valid = false end
                end
            end
            known.previewKeys = {}
            if valid then for _, key in ipairs(keys) do known.previewKeys[key] = true end
            else log("VISUAL_PREVIEW_KEYS_INVALID", tostring(provider.modId)) end
        end
        facts[provider] = known
        return known
    end

    local function supported(record)
        local provider = type(record) == "table" and record.provider or nil
        return type(provider) == "table" and provider.async ~= true and record.error == nil and record.readFailed ~= true
            and type(provider.createVisualPreview) == "function"
    end

    local function previewable(provider, key)
        local known = factsOf(provider)
        return known.values[key] ~= nil and (known.previewKeys == nil or known.previewKeys[key] == true)
    end

    local self = {}

    function self.has(record, key)
        if not supported(record) then return false end
        local known = factsOf(record.provider)
        if key == nil then return true end
        return previewable(record.provider, key) and known ~= nil
    end

    function self.stop()
        generation = generation + 1
        local old = visual
        visual = nil
        if old then
            local ok, err = pcall(old.controller.dispose)
            if not ok then log("VISUAL_PREVIEW_STOP_FAILED", tostring(err)) end
        end
        return generation
    end

    local function update(own, key, draft)
        if visual ~= own then return false end
        local provider = own.record.provider
        if own.record.provider ~= own.provider or not previewable(provider, key) then self.stop(); return false end
        local readOk, current = pcall(provider.read)
        if not readOk or not validSnapshot(current) then self.stop(); return false end
        local values = copy(current.values)
        local entry = factsOf(provider).values[key]
        -- Only a validated colour draft for this key and revision may override the saved value.
        if type(draft) == "table" and draft.key == key and draft.revision == current.revision and entry.type == "color"
            and Core.enabled(entry, values) and Core.visible(entry, values) and Core.valueError(entry, draft.value) == nil then
            values[key] = draft.value
        end
        local ok, err = pcall(own.controller.update, {key = key, values = values, locale = locale(), revision = current.revision})
        if ok then return true end
        self.stop()
        log("VISUAL_PREVIEW_FAILED", tostring(err))
        return false
    end

    function self.open(record, context)
        local started = self.stop()
        if started ~= generation then return {ok = false, error = "PREVIEW_CHANGED"} end
        if disposed or not supported(record) then return {ok = false, error = "PREVIEW_UNAVAILABLE"} end
        local provider = record.provider
        local controller
        local ok, err = pcall(function()
            controller = provider.createVisualPreview(context)
            if type(controller) ~= "table" or type(controller.update) ~= "function" or type(controller.dispose) ~= "function"
                or type(controller["then"]) == "function" then error("INVALID_VISUAL_PREVIEW", 0) end
        end)
        if not ok then
            if type(controller) == "table" and type(controller.dispose) == "function" then
                local cleaned, cleanup = pcall(controller.dispose)
                if not cleaned then log("VISUAL_PREVIEW_STOP_FAILED", tostring(cleanup)) end
            end
            log("VISUAL_PREVIEW_FAILED", tostring(err))
            return {ok = false, error = "PREVIEW_FAILED"}
        end
        -- The factory may have re-entered stop/open or the record may have been retired meanwhile.
        if started ~= generation or disposed or record.provider ~= provider then
            local cleaned, cleanup = pcall(controller.dispose)
            if not cleaned then log("VISUAL_PREVIEW_STOP_FAILED", tostring(cleanup)) end
            return {ok = false, error = "PREVIEW_CHANGED"}
        end
        local own = {record = record, provider = provider, controller = controller}
        visual = own
        return {ok = true,
            update = function(key, draft) return update(own, key, draft) end,
            dispose = function() if visual == own then self.stop() end end}
    end

    function self.update(key, draft)
        if not visual then return false end
        return update(visual, key, draft)
    end

    -- Record of the open preview (nil when none). Runtime uses it to release on provider changes.
    function self.owner() return visual and visual.record or nil end

    function self.release(record)
        if visual and visual.record == record then self.stop() end
    end

    function self.dispose()
        if disposed then return end
        self.stop()
        disposed = true
    end

    return self
end

return Visual
