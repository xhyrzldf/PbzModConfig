-- Port of src/Navigation.js (ModConfig 0.3.13). One gate owns each physical
-- axis: analog events and their synthetic keys share a state, and a neutral
-- horizontal sample never releases vertical input. Time is injected (ms).
local Navigation = {}

local keys = {
    Up = {"keyboard", "y", -1}, W = {"keyboard", "y", -1}, Down = {"keyboard", "y", 1}, S = {"keyboard", "y", 1},
    Left = {"keyboard", "x", -1}, A = {"keyboard", "x", -1}, Right = {"keyboard", "x", 1}, D = {"keyboard", "x", 1},
    Gamepad_DPad_Up = {"pad", "y", -1}, Gamepad_DPad_Down = {"pad", "y", 1},
    Gamepad_DPad_Left = {"pad", "x", -1}, Gamepad_DPad_Right = {"pad", "x", 1},
    Gamepad_LeftStick_Up = {"stick", "y", -1}, Gamepad_LeftStick_Down = {"stick", "y", 1},
    Gamepad_LeftStick_Left = {"stick", "x", -1}, Gamepad_LeftStick_Right = {"stick", "x", 1},
}
local INITIAL_MS, REPEAT_MS, LIGHT_REPEAT_MS = 380, 180, 260
local ENTER, RELEASE, ANALOG_LEASE_MS = 0.6, 0.28, 500

local function sign(value)
    if value > 0 then return 1 elseif value < 0 then return -1 end
    return 0
end

function Navigation.create(options)
    options = options or {}
    local now = options.now or function() return os.clock() * 1000 end
    local held, analogSeen = {}, {}
    local stats = {keyEvents = 0, axisEvents = 0, accepted = 0, suppressed = 0}
    local self = {}

    local function result(axis, delta, fire)
        stats[fire and "accepted" or "suppressed"] = stats[fire and "accepted" or "suppressed"] + 1
        return {kind = axis == "y" and "move" or "step", delta = delta, fire = fire}
    end

    local function press(device, axis, delta, pressure)
        pressure = pressure or 1
        local t, id = now(), device .. axis
        local previous = held[id]
        if not previous or previous.delta ~= delta or t < previous.last then
            held[id] = {delta = delta, last = t, next = t + INITIAL_MS}
            return result(axis, delta, true)
        end
        if t < previous.next then return result(axis, delta, false) end
        previous.last = t
        previous.next = t + (pressure < 0.85 and LIGHT_REPEAT_MS or REPEAT_MS)
        return result(axis, delta, true) -- Never catch up missed repeats after a slow frame.
    end

    local function stickLeased(axis, t)
        local last = analogSeen[axis]
        return last ~= nil and t >= last and t - last < ANALOG_LEASE_MS
    end

    function self.key(name)
        local k = keys[name]
        if not k then return nil end
        stats.keyEvents = stats.keyEvents + 1
        local device, axis, delta = k[1], k[2], k[3]
        local t = now()
        if device == "stick" and stickLeased(axis, t) then return result(axis, delta, false) end
        return press(device, axis, delta)
    end

    function self.keyUp(name)
        local k = keys[name]
        if not k then return false end
        local device, axis, delta = k[1], k[2], k[3]
        local t = now()
        if device == "stick" and stickLeased(axis, t) then return true end
        local state = held[device .. axis]
        if state and state.delta == delta then held[device .. axis] = nil end
        return true
    end

    function self.analog(name, value)
        local axis = name == "Gamepad_LeftX" and "x" or (name == "Gamepad_LeftY" and "y" or nil)
        if not axis then return nil end
        stats.axisEvents = stats.axisEvents + 1
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
            return result(axis, 0, false)
        end
        local t, id = now(), "stick" .. axis
        local previous = held[id]
        local pressure = math.abs(value)
        local delta = (axis == "y" and -1 or 1) * sign(value)
        analogSeen[axis] = t
        if pressure < RELEASE then held[id] = nil; return result(axis, 0, false) end
        if pressure < ENTER and (not previous or previous.delta ~= delta) then return result(axis, delta, false) end
        return press("stick", axis, delta, pressure)
    end

    function self.reset() held, analogSeen = {}, {} end

    function self.inspect()
        return {keyEvents = stats.keyEvents, axisEvents = stats.axisEvents, accepted = stats.accepted,
            suppressed = stats.suppressed, initialMs = INITIAL_MS, repeatMs = REPEAT_MS,
            lightRepeatMs = LIGHT_REPEAT_MS, enter = ENTER, release = RELEASE}
    end

    function self.flush()
        local summary = self.inspect()
        stats = {keyEvents = 0, axisEvents = 0, accepted = 0, suppressed = 0}
        self.reset()
        return summary
    end

    return self
end

return Navigation
