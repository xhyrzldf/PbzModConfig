-- Port of src/ColorPalette.js: pure HSV/colour-wheel geometry used by the
-- colour editor. Colours are the stable "#RRGGBB[AA]" strings of the protocol.
local Core = require("PbzConfigCore")
local Palette = {}

local function clamp(value) return math.max(0, math.min(1, value)) end
local function round(value) return math.floor(value + 0.5) end

function Palette.hsv(hex)
    local channels = Core.colorChannels(hex)
    local rgb = {channels[1] / 255, channels[2] / 255, channels[3] / 255}
    local max, min = math.max(rgb[1], rgb[2], rgb[3]), math.min(rgb[1], rgb[2], rgb[3])
    local d = max - min
    local h = 0
    if d ~= 0 then
        local index = 1
        if rgb[1] == max then index = 1 elseif rgb[2] == max then index = 2 else index = 3 end
        if index == 1 then h = 60 * ((rgb[2] - rgb[3]) / d)
        elseif index == 2 then h = 60 * ((rgb[3] - rgb[1]) / d + 2)
        else h = 60 * ((rgb[1] - rgb[2]) / d + 4) end
    end
    -- JS remainder keeps the dividend's sign; (h + 360) % 360 matches for every finite h here.
    return {h = (h + 360) % 360, s = max ~= 0 and d / max or 0, v = max}
end

function Palette.rgb(h, s, v)
    h = ((h % 360) + 360) % 360
    s, v = clamp(s), clamp(v)
    local c = v * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local table6 = {{c, x, 0}, {x, c, 0}, {0, c, x}, {0, x, c}, {x, 0, c}, {c, 0, x}}
    local values = table6[math.floor(h / 60) + 1]
    return {round((values[1] + m) * 255), round((values[2] + m) * 255), round((values[3] + m) * 255)}
end

local function finite(value) return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge end

-- (x, y) are local widget coordinates (y grows downward). Returns nil outside the disc.
function Palette.wheel(hex, x, y, size)
    if not (finite(x) and finite(y) and finite(size)) or size <= 0 then return nil end
    local dx, dy = x - size / 2, size / 2 - y
    local r = math.sqrt(dx * dx + dy * dy) / (size / 2)
    if r > 1 then return nil end
    local channels = Core.colorChannels(hex)
    local current = Palette.hsv(hex)
    -- A black starting colour must still let the player see the colour they pick.
    local v = current.v
    if v == 0 then v = 1 end
    local out = Palette.rgb(math.atan(dy, dx) * 180 / math.pi, r, v)
    for index = 4, #channels do out[#out + 1] = channels[index] end
    return Core.colorValue(out)
end

function Palette.marker(hex, size)
    local c = Palette.hsv(hex)
    local angle = c.h * math.pi / 180
    return {x = size / 2 + math.cos(angle) * c.s * size / 2, y = size / 2 - math.sin(angle) * c.s * size / 2}
end

function Palette.brightness(hex, value)
    local channels = Core.colorChannels(hex)
    local c = Palette.hsv(hex)
    local out = Palette.rgb(c.h, c.s, clamp(value))
    for index = 4, #channels do out[#out + 1] = channels[index] end
    return Core.colorValue(out)
end

return Palette
