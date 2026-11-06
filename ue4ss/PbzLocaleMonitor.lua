local Locale = require('PbzLocale')
local Monitor = {}

-- Called on the game thread. The scheduler must invoke subsequent callbacks on
-- that same thread; no async Lua loop may touch Unreal objects.
function Monitor.start(deps)
    assert(type(deps) == 'table' and type(deps.nativeText) == 'function'
        and type(deps.engineLanguage) == 'function' and type(deps.schedule) == 'function', 'LOCALE_DEPS_INVALID')
    local current, stopped = deps.initial or 'zhHans', false
    local report = deps.report or function() end
    local tick
    tick = function()
        if stopped then return end
        current = Locale.gameLanguage(deps.nativeText, deps.engineLanguage, current)
        local ok, err = pcall(deps.schedule, 500, tick)
        if not ok then report('LOCALE_TIMER_FAILED', tostring(err)) end
    end
    local self = {}
    function self.resolve(value) return Locale.resolve(value, current) end
    function self.current() return current end
    function self.stop() stopped = true end
    tick()
    return self
end
return Monitor
