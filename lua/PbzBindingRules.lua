local Rules = {}
local modifiers = {"Ctrl", "Alt", "Shift", "Cmd"}
local modifierOrder = {Ctrl = 1, Alt = 2, Shift = 3, Cmd = 4}
local modifierKeys = {LeftControl = true, RightControl = true, LeftAlt = true, RightAlt = true,
    LeftShift = true, RightShift = true, LeftCommand = true, RightCommand = true}

local function contains(values, expected)
    for _, value in ipairs(values or {}) do if value == expected then return true end end
    return false
end

function Rules.parse(value)
    local parts = {}
    for part in (value .. "+"):gmatch("(.-)%+") do parts[#parts + 1] = part end
    local key = table.remove(parts)
    local held = {}
    for _, name in ipairs(parts) do held[name] = true end
    return key, held, parts
end

function Rules.bindingError(entry, value)
    if type(value) ~= "string" then return "EXPECTED_BINDING" end
    if value == "" then return entry.allowUnbound == false and "BINDING_REQUIRED" or nil end
    local key, _, parts = Rules.parse(value)
    if #key > 64 or not key:match("^[A-Za-z][A-Za-z0-9_]*$") or modifierKeys[key] or modifierOrder[key] then
        return "INVALID_KEY"
    end
    local previous = 0
    for _, name in ipairs(parts) do
        local order = modifierOrder[name]
        if not order or order <= previous then return "INVALID_MODIFIERS" end
        previous = order
    end
    if #parts > 0 and entry.allowModifiers == false then return "MODIFIERS_DISABLED" end
    if key:match("^Gamepad_") and (entry.allowGamepad == false or #parts > 0) then
        return "GAMEPAD_BINDING_DISABLED"
    end
    if entry.allowMouse == false and (key:match("MouseButton[0-9]*$") or key:match("MouseScrollUp$") or key:match("MouseScrollDown$")) then
        return "MOUSE_BINDING_DISABLED"
    end
    if key == "Escape" or key == "Gamepad_FaceButton_Right" or contains(entry.reservedKeys, key) then return "RESERVED_KEY" end
    if entry.allowedKeys and not contains(entry.allowedKeys, key) then return "KEY_NOT_ALLOWED" end
    return nil
end

function Rules.chord(key, held)
    local parts = {}
    for _, name in ipairs(modifiers) do
        if held and held[name] then parts[#parts + 1] = name end
    end
    parts[#parts + 1] = key
    return table.concat(parts, "+")
end

return Rules
