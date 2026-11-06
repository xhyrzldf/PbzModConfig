-- Pure-Lua core shared by the ModConfig host, the third-party client and the
-- generic store: strict JSON, descriptor validation and control value rules.
-- Ports provider/Schema.js and provider/Controls.js (ModConfig 0.3.13). No UE
-- API is used here, so the same file runs in tests and in every UE4SS Lua state.
local Core = {}

---------------------------------------------------------------------------
-- JSON (RFC 8259, strict). Arrays decode with a shared metatable so empty
-- arrays survive a round trip; `json.null` is a unique sentinel.
---------------------------------------------------------------------------
local json = {}
Core.json = json
local ARRAY = {__jsontype = "array"}
local OBJECT = {__jsontype = "object"}
json.null = setmetatable({}, {__tostring = function() return "null" end, __jsontype = "null"})
json.MAX_DEPTH = 64

function json.array(value) return setmetatable(value or {}, ARRAY) end
function json.object(value) return setmetatable(value or {}, OBJECT) end
function json.isArray(value)
    if type(value) ~= "table" or value == json.null then return false end
    if getmetatable(value) == ARRAY then return true end
    if getmetatable(value) ~= nil then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
    end
    return count == #value
end
function json.isObject(value)
    if type(value) ~= "table" or value == json.null then return false end
    local meta = getmetatable(value)
    if meta ~= nil and meta ~= OBJECT then return false end
    for key in pairs(value) do if type(key) ~= "string" then return false end end
    return true
end

local escapes = {['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"}
local function encodeString(value)
    assert(utf8.len(value), "JSON_INVALID_UTF8")
    return '"' .. value:gsub('[%c"\\]', function(char)
        return escapes[char] or string.format("\\u%04x", char:byte())
    end) .. '"'
end

local function encodeNumber(value)
    assert(value == value and value ~= math.huge and value ~= -math.huge, "JSON_NONFINITE_NUMBER")
    if value % 1 == 0 and math.abs(value) <= 9007199254740991 then return string.format("%d", value) end
    for precision = 1, 17 do
        local text = string.format("%." .. precision .. "g", value)
        if tonumber(text) == value then return text end
    end
    return string.format("%.17g", value)
end

local function encodeValue(value, depth, out)
    assert(depth <= json.MAX_DEPTH, "JSON_TOO_DEEP")
    local kind = type(value)
    if value == json.null then out[#out + 1] = "null"
    elseif kind == "boolean" then out[#out + 1] = value and "true" or "false"
    elseif kind == "number" then out[#out + 1] = encodeNumber(value)
    elseif kind == "string" then out[#out + 1] = encodeString(value)
    elseif kind == "table" then
        if json.isArray(value) then
            out[#out + 1] = "["
            for index = 1, #value do
                if index > 1 then out[#out + 1] = "," end
                encodeValue(value[index], depth + 1, out)
            end
            out[#out + 1] = "]"
        else
            assert(json.isObject(value), "JSON_UNSUPPORTED_TABLE")
            local keys = {}
            for key in pairs(value) do keys[#keys + 1] = key end
            table.sort(keys)
            out[#out + 1] = "{"
            for index, key in ipairs(keys) do
                if index > 1 then out[#out + 1] = "," end
                out[#out + 1] = encodeString(key) .. ":"
                encodeValue(value[key], depth + 1, out)
            end
            out[#out + 1] = "}"
        end
    else error("JSON_UNSUPPORTED_TYPE " .. kind, 0) end
end

function json.encode(value)
    local out = {}
    encodeValue(value, 1, out)
    return table.concat(out)
end

local function utf8char(code)
    return utf8.char(code)
end

function json.decode(text, limit)
    if type(text) ~= "string" then return nil, "JSON_NOT_A_STRING" end
    if #text > (limit or 1048576) then return nil, "JSON_TOO_LARGE" end
    local position, length = 1, #text
    local function fail(code) error({code = code}, 0) end
    local function skip()
        while true do
            local byte = text:byte(position)
            if byte == 32 or byte == 9 or byte == 10 or byte == 13 then position = position + 1 else return end
        end
    end
    local parse
    local function parseString()
        position = position + 1
        local pieces, start = {}, position
        while true do
            local byte = text:byte(position)
            if not byte then fail("JSON_UNTERMINATED_STRING") end
            if byte == 34 then
                pieces[#pieces + 1] = text:sub(start, position - 1)
                position = position + 1
                local result = table.concat(pieces)
                if not utf8.len(result) then fail("JSON_INVALID_UTF8") end
                return result
            elseif byte < 32 then fail("JSON_CONTROL_IN_STRING")
            elseif byte == 92 then
                pieces[#pieces + 1] = text:sub(start, position - 1)
                local escape = text:sub(position + 1, position + 1)
                position = position + 2
                local simple = ({['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t"})[escape]
                if simple then pieces[#pieces + 1] = simple
                elseif escape == "u" then
                    local hex = text:sub(position, position + 3)
                    if not hex:match("^%x%x%x%x$") then fail("JSON_BAD_ESCAPE") end
                    local code = tonumber(hex, 16)
                    position = position + 4
                    if code >= 0xD800 and code <= 0xDBFF then
                        local low = text:sub(position, position + 5)
                        if not low:match("^\\u[dD][c-fC-F]%x%x$") then fail("JSON_BAD_SURROGATE") end
                        code = 0x10000 + ((code - 0xD800) << 10) + (tonumber(low:sub(3), 16) - 0xDC00)
                        position = position + 6
                    elseif code >= 0xDC00 and code <= 0xDFFF then fail("JSON_BAD_SURROGATE") end
                    pieces[#pieces + 1] = utf8char(code)
                else fail("JSON_BAD_ESCAPE") end
                start = position
            else position = position + 1 end
        end
    end
    parse = function(depth)
        if depth > json.MAX_DEPTH then fail("JSON_TOO_DEEP") end
        skip()
        local char = text:sub(position, position)
        if char == '"' then return parseString()
        elseif char == "{" then
            position = position + 1
            local result = setmetatable({}, OBJECT)
            skip()
            if text:sub(position, position) == "}" then position = position + 1; return result end
            while true do
                skip()
                if text:sub(position, position) ~= '"' then fail("JSON_EXPECTED_KEY") end
                local key = parseString()
                skip()
                if text:sub(position, position) ~= ":" then fail("JSON_EXPECTED_COLON") end
                position = position + 1
                result[key] = parse(depth + 1)
                skip()
                local separator = text:sub(position, position)
                position = position + 1
                if separator == "}" then return result end
                if separator ~= "," then fail("JSON_EXPECTED_COMMA") end
            end
        elseif char == "[" then
            position = position + 1
            local result = setmetatable({}, ARRAY)
            skip()
            if text:sub(position, position) == "]" then position = position + 1; return result end
            while true do
                result[#result + 1] = parse(depth + 1)
                skip()
                local separator = text:sub(position, position)
                position = position + 1
                if separator == "]" then return result end
                if separator ~= "," then fail("JSON_EXPECTED_COMMA") end
            end
        elseif text:sub(position, position + 3) == "true" then position = position + 4; return true
        elseif text:sub(position, position + 4) == "false" then position = position + 5; return false
        elseif text:sub(position, position + 3) == "null" then position = position + 4; return json.null
        else
            local number = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", position)
            local valid = number and (number:match("^-?0$") or number:match("^-?[1-9]%d*$") or number:match("^-?0%.%d+$")
                or number:match("^-?[1-9]%d*%.%d+$") or number:match("^-?0[eE][+-]?%d+$") or number:match("^-?[1-9]%d*[eE][+-]?%d+$")
                or number:match("^-?0%.%d+[eE][+-]?%d+$") or number:match("^-?[1-9]%d*%.%d+[eE][+-]?%d+$"))
            if not valid then fail("JSON_BAD_VALUE") end
            position = position + #number
            local value = tonumber(number)
            if value == nil or value ~= value or value == math.huge or value == -math.huge then fail("JSON_BAD_NUMBER") end
            if value % 1 == 0 and math.abs(value) <= 9007199254740991 then value = math.tointeger(value) or value end
            return value
        end
    end
    local ok, result = pcall(function()
        local value = parse(1)
        skip()
        if position <= length then fail("JSON_TRAILING_DATA") end
        return value
    end)
    if ok then return result end
    if type(result) == "table" and result.code then return nil, result.code end
    return nil, tostring(result)
end

---------------------------------------------------------------------------
-- Plain data helpers
---------------------------------------------------------------------------
function Core.copy(value, depth)
    depth = depth or 0
    assert(depth <= json.MAX_DEPTH, "DATA_TOO_DEEP")
    if type(value) ~= "table" then
        assert(type(value) ~= "function" and type(value) ~= "userdata" and type(value) ~= "thread", "DATA_NOT_PLAIN")
        return value
    end
    if value == json.null then return value end
    local result = {}
    for key, item in pairs(value) do
        assert(type(key) == "string" or type(key) == "number", "DATA_NOT_PLAIN")
        result[key] = Core.copy(item, depth + 1)
    end
    local meta = getmetatable(value)
    return (meta == ARRAY or meta == OBJECT) and setmetatable(result, meta) or result
end

local function own(object, key) return type(object) == "table" and rawget(object, key) ~= nil end
Core.own = own

function Core.validId(value)
    return type(value) == "string" and #value <= 96 and value:match("^[A-Za-z][A-Za-z0-9_.-]*$") ~= nil
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
Core.finite = finite

---------------------------------------------------------------------------
-- Control value rules (Controls.js)
---------------------------------------------------------------------------
local MODIFIERS = {"Ctrl", "Alt", "Shift", "Cmd"}
local MODIFIER_ORDER = {Ctrl = 1, Alt = 2, Shift = 3, Cmd = 4}
local MODIFIER_KEYS = {LeftControl = true, RightControl = true, LeftAlt = true, RightAlt = true,
    LeftShift = true, RightShift = true, LeftCommand = true, RightCommand = true}
Core.MODIFIERS, Core.MODIFIER_KEYS = MODIFIERS, MODIFIER_KEYS
Core.EXTENDED = {keybind = true, color = true, sound = true}

local function contains(list, expected)
    for _, item in ipairs(list or {}) do if item == expected then return true end end
    return false
end

function Core.bindingError(entry, value)
    if type(value) ~= "string" then return "EXPECTED_BINDING" end
    if value == "" then return entry.allowUnbound == false and "BINDING_REQUIRED" or nil end
    local parts = {}
    for part in (value .. "+"):gmatch("(.-)%+") do parts[#parts + 1] = part end
    local key = table.remove(parts)
    if #key > 64 or not key:match("^[A-Za-z][A-Za-z0-9_]*$") or MODIFIER_KEYS[key] or MODIFIER_ORDER[key] then
        return "INVALID_KEY"
    end
    local previous = 0
    for _, name in ipairs(parts) do
        local order = MODIFIER_ORDER[name]
        if not order or order <= previous then return "INVALID_MODIFIERS" end
        previous = order
    end
    if #parts > 0 and entry.allowModifiers == false then return "MODIFIERS_DISABLED" end
    if key:match("^Gamepad_") and (entry.allowGamepad == false or #parts > 0) then return "GAMEPAD_BINDING_DISABLED" end
    if entry.allowMouse == false and (key:match("MouseButton%d*$") or key:match("MouseScrollUp$") or key:match("MouseScrollDown$")) then
        return "MOUSE_BINDING_DISABLED"
    end
    if key == "Escape" or key == "Gamepad_FaceButton_Right" or contains(entry.reservedKeys, key) then return "RESERVED_KEY" end
    if entry.allowedKeys and not contains(entry.allowedKeys, key) then return "KEY_NOT_ALLOWED" end
    return nil
end

function Core.chord(key, modifiers)
    local parts = {}
    for _, name in ipairs(MODIFIERS) do if modifiers and modifiers[name] then parts[#parts + 1] = name end end
    parts[#parts + 1] = key
    return table.concat(parts, "+")
end

function Core.colorError(entry, value)
    if type(value) ~= "string" then return "INVALID_COLOR" end
    local digits = entry.alpha and 8 or 6
    if #value == digits + 1 and value:match("^#%x+$") then return nil end
    return "INVALID_COLOR"
end

function Core.colorChannels(value)
    local channels = {}
    for index = 2, #value, 2 do channels[#channels + 1] = tonumber(value:sub(index, index + 1), 16) end
    return channels
end

function Core.colorValue(channels)
    local out = "#"
    for _, channel in ipairs(channels) do out = out .. string.format("%02X", math.floor(channel + 0.5)) end
    return out
end

-- schema.valueList is ordered; JS Map insertion order decides which binding of a
-- conflicting pair is reported first, so the order is kept.
function Core.conflicts(schema, values)
    local used, errors = {}, {}
    for _, entry in ipairs(schema.valueList) do
        local value = values[entry.key]
        if entry.type == "keybind" and value and value ~= "" and entry.conflictGroup ~= false then
            local token = (entry.conflictGroup or "default") .. ":" .. value
            if used[token] then errors[entry.key] = "BINDING_CONFLICT"; errors[used[token]] = "BINDING_CONFLICT"
            else used[token] = entry.key end
        end
    end
    return errors
end

---------------------------------------------------------------------------
-- Schema (Schema.js)
---------------------------------------------------------------------------
local TYPES = {toggle = true, number = true, choice = true, header = true, action = true, keybind = true, color = true, sound = true}
local VALUE_TYPES = {toggle = true, number = true, choice = true, keybind = true, color = true, sound = true}
Core.TYPES, Core.VALUE_TYPES = TYPES, VALUE_TYPES

local function text(value, optional)
    if optional and value == nil then return true end
    if type(value) == "string" then return true end
    if not json.isObject(value) or next(value) == nil then return false end
    for _, item in pairs(value) do if type(item) ~= "string" then return false end end
    return true
end

function Core.valueError(entry, value)
    local kind = entry.type
    if kind == "keybind" then return Core.bindingError(entry, value) end
    if kind == "color" then return Core.colorError(entry, value) end
    if kind == "toggle" then if type(value) == "boolean" then return nil end return "EXPECTED_BOOLEAN" end
    if kind == "choice" or kind == "sound" then
        for _, option in ipairs(entry.options) do if option.value == value then return nil end end
        return "UNKNOWN_CHOICE"
    end
    if kind == "number" then
        if not finite(value) then return "EXPECTED_FINITE_NUMBER" end
        if value < entry.min or value > entry.max then return "OUT_OF_RANGE" end
        local units = (value - entry.min) / entry.step
        if math.abs(units - math.floor(units + 0.5)) > 1e-7 then return "OFF_STEP" end
        return nil
    end
    return "NOT_A_VALUE"
end

local function fail(message) error(message, 0) end

local function checkCondition(rule)
    if rule == nil then return end
    if not json.isObject(rule) or not Core.validId(rule.key) or rule.equals == nil then fail("INVALID_CONDITION") end
end

-- Returns schema = {groups, groupList, entries, entryList, values, valueList, defaults}.
function Core.compile(descriptor, report)
    report = report or function() end
    if type(descriptor) ~= "table" or descriptor.apiVersion ~= 1 or not Core.validId(descriptor.modId)
        or not finite(descriptor.schemaVersion) or descriptor.schemaVersion < 1 or descriptor.schemaVersion % 1 ~= 0
        or descriptor.schemaVersion > 9007199254740991
        or not text(descriptor.displayName) or not json.isArray(descriptor.entries) or not json.isArray(descriptor.groups) then
        fail("INVALID_DESCRIPTOR")
    end
    local schema = {groups = {}, groupList = {}, entries = {}, entryList = {}, values = {}, valueList = {}, defaults = {}}
    for _, source in ipairs(descriptor.groups) do
        if not json.isObject(source) or not Core.validId(source.id) or schema.groups[source.id] or not text(source.label)
            or (source.order ~= nil and not finite(source.order)) then fail("INVALID_GROUP") end
        local group = Core.copy(source)
        schema.groups[group.id] = group
        schema.groupList[#schema.groupList + 1] = group
    end
    for _, source in ipairs(descriptor.entries) do
        if not json.isObject(source) or not Core.validId(source.key) or schema.entries[source.key] then fail("INVALID_ENTRY_KEY") end
        if not TYPES[source.type] then
            report({code = "UNKNOWN_CONTROL", key = source.key, type = source.type})
        else
            -- Validate conditions before copying; copy() rejects functions anyway.
            checkCondition(source.enabledWhen); checkCondition(source.visibleWhen)
            local entry = Core.copy(source)
            if not text(entry.label) or not text(entry.description, true) or not text(entry.disabledReason, true)
                or (entry.group ~= nil and not schema.groups[entry.group])
                or (entry.applyMode ~= nil and entry.applyMode ~= "immediate") then fail("INVALID_ENTRY: " .. entry.key) end
            if entry.type == "number" then
                local span = finite(entry.min) and finite(entry.max) and finite(entry.step) and (entry.max - entry.min) / entry.step
                if not span or entry.min >= entry.max or entry.step <= 0 or span > 1e9
                    or math.abs(span - math.floor(span + 0.5)) > 1e-7
                    or (entry.format ~= nil and not (type(entry.format) == "string" and entry.format:match("^[FP][0-6]$"))) then
                    fail("INVALID_NUMBER: " .. entry.key)
                end
            end
            if entry.type == "choice" or entry.type == "sound" then
                local seen = {}
                if not json.isArray(entry.options) or #entry.options < 1 then fail("INVALID_OPTIONS: " .. entry.key) end
                for _, option in ipairs(entry.options) do
                    if not json.isObject(option) or type(option.value) ~= "string" or option.value == "" or not text(option.label)
                        or seen[option.value] then fail("INVALID_OPTIONS: " .. entry.key) end
                    seen[option.value] = true
                end
            end
            if entry.type == "keybind" then
                for _, flag in ipairs({"allowModifiers", "allowGamepad", "allowMouse", "allowUnbound"}) do
                    if entry[flag] ~= nil and type(entry[flag]) ~= "boolean" then fail("INVALID_KEYBIND: " .. entry.key) end
                end
                for _, field in ipairs({"allowedKeys", "reservedKeys"}) do
                    local list = entry[field]
                    if list ~= nil then
                        if not json.isArray(list) or #list == 0 then fail("INVALID_KEYBIND: " .. entry.key) end
                        for _, key in ipairs(list) do
                            if type(key) ~= "string" or #key > 64 or not key:match("^[A-Za-z][A-Za-z0-9_]*$") then fail("INVALID_KEYBIND: " .. entry.key) end
                        end
                    end
                end
                if entry.conflictGroup ~= nil and entry.conflictGroup ~= false
                    and (type(entry.conflictGroup) ~= "string" or not Core.validId(entry.conflictGroup)) then fail("INVALID_KEYBIND_GROUP") end
            end
            if entry.type == "color" and entry.alpha ~= nil and type(entry.alpha) ~= "boolean" then fail("INVALID_COLOR_ALPHA") end
            schema.entries[entry.key] = entry
            schema.entryList[#schema.entryList + 1] = entry
            if VALUE_TYPES[entry.type] then
                local problem = Core.valueError(entry, entry.defaultValue)
                if problem then fail("INVALID_DEFAULT: " .. entry.key .. " " .. problem) end
                schema.values[entry.key] = entry
                schema.valueList[#schema.valueList + 1] = entry
                schema.defaults[entry.key] = entry.defaultValue
            end
        end
    end
    if next(Core.conflicts(schema, schema.defaults)) then fail("CONFLICTING_DEFAULT_BINDINGS") end
    for _, entry in ipairs(schema.entryList) do
        for _, rule in ipairs({entry.enabledWhen or false, entry.visibleWhen or false}) do
            if rule then
                local target = schema.values[rule.key]
                if not target or Core.valueError(target, rule.equals) then fail("INVALID_CONDITION_TARGET") end
            end
        end
    end
    return schema
end

function Core.validatePatch(schema, patch, current)
    local errors = {}
    if not json.isObject(patch) then return {_patch = "EXPECTED_OBJECT"} end
    for key, value in pairs(patch) do
        local entry = schema.values[key]
        local problem = entry and Core.valueError(entry, value) or (not entry and "UNKNOWN_KEY") or nil
        if problem then errors[key] = problem end
    end
    if next(errors) == nil and current then
        local merged = {}
        for key, value in pairs(current) do merged[key] = value end
        for key, value in pairs(patch) do merged[key] = value end
        for key, value in pairs(Core.conflicts(schema, merged)) do errors[key] = value end
    end
    return errors
end

function Core.enabled(entry, values)
    return entry.enabledWhen == nil or values[entry.enabledWhen.key] == entry.enabledWhen.equals
end

function Core.visible(entry, values)
    return entry.visibleWhen == nil or values[entry.visibleWhen.key] == entry.visibleWhen.equals
end

return Core
