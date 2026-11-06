-- Low-overhead diagnostics (port of native/Diagnostics.js, ModConfig 0.3.13).
-- Memory only: no timers, no console, no files. At most 24 distinct codes are kept (the oldest is
-- dropped first), a code is at most 64 characters of [A-Z][A-Z0-9_]*, anything else is counted as
-- OTHER, counters stop at 2147483647 and the stored cause is a coarse class, never the raw error text.
local Diagnostics = {LIMITS = {events = 24, codeLength = 64, count = 2147483647, detail = 160}}

function Diagnostics.cause(detail)
    if type(detail) ~= "string" then return "none" end
    local lower = detail:lower()
    if lower:find("invalid object", 1, true) or lower:find("is not valid", 1, true) or lower:find("destroyed", 1, true) then
        return "destroyed_object"
    end
    if lower:find("attempt to ", 1, true) then return "type_error" end
    return "other"
end

-- options: version, now() -> seconds
function Diagnostics.create(options)
    options = options or {}
    local now = options.now or os.clock
    local startedAt = now()
    local events, order, dropped = {}, {}, 0
    local limits = Diagnostics.LIMITS
    local self = {}

    -- Returns true for the first occurrence of a code (since it was last evicted).
    function self.report(code, detail)
        if not (type(code) == "string" and #code <= limits.codeLength and code:match("^[A-Z][A-Z0-9_]*$")) then
            code = "OTHER"
        end
        local t = math.max(startedAt, now())
        local item = events[code]
        local first = false
        if not item then
            first = true
            if #order == limits.events then
                events[table.remove(order, 1)] = nil
                dropped = math.min(limits.count, dropped + 1)
            end
            item = {code = code, count = 0, firstAt = t, lastAt = t, cause = "none"}
            events[code] = item
            order[#order + 1] = code
        end
        item.count = math.min(limits.count, item.count + 1)
        item.lastAt = math.max(item.lastAt, t)
        if type(detail) == "string" then detail = detail:sub(1, limits.detail) else detail = nil end
        item.cause = Diagnostics.cause(detail)
        return first
    end

    -- Explicit bounded snapshot for local debugging; nothing serialises it on its own.
    function self.snapshot()
        local list = {}
        for _, code in ipairs(order) do
            local item = events[code]
            list[#list + 1] = {code = item.code, count = item.count, firstAt = item.firstAt, lastAt = item.lastAt,
                cause = item.cause}
        end
        return {version = options.version, startedAt = startedAt, dropped = dropped, events = list}
    end

    return self
end

-- Wraps a log function. Every report is counted. Verbose (test builds): the original line is
-- forwarded. Quiet (players): only the first occurrence of each code is forwarded, as the bare code.
-- verbose may be a boolean or a function evaluated per report.
function Diagnostics.sink(diagnostics, forward, verbose)
    return function(code, detail)
        local first = diagnostics.report(code, detail)
        if type(forward) ~= "function" then return end
        local loud = type(verbose) == "function" and verbose() or verbose == true
        if loud then return forward(code, detail) end
        if first then return forward(type(code) == "string" and code or "OTHER", "") end
    end
end

return Diagnostics
