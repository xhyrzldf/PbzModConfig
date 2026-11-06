-- Locale-aware number text for number rows (format F0..F6 / P0..P6), the Lua counterpart of
-- Intl.NumberFormat(tag, {style, minimumFractionDigits = n, maximumFractionDigits = n, useGrouping = false}) in
-- src/Localization.js. Only the eight game languages are tabulated (checked against ICU in
-- tests/test_number_format.py); any other tag formats like English.
--
-- The JS code falls back to toFixed(n) + "%" when the game's JS engine has no Intl, and nobody has seen which
-- of the two the game printed, so PbzModConfigRuntime uses this only with capabilities.localizedNumbers.
local Format = {}

-- decimal separator, and whether the percent sign follows a no-break space
local LOCALES = {
    zhHans = {decimal = "."}, zhHant = {decimal = "."}, en = {decimal = "."}, ko = {decimal = "."},
    ru = {decimal = ",", percentSpace = true}, ["es-ES"] = {decimal = ",", percentSpace = true},
    ["es-419"] = {decimal = "."}, vi = {decimal = ","},
}
local NO_BREAK_SPACE = "\u{00A0}"

local function knowledge(locale)
    return LOCALES[locale] or LOCALES.en
end

-- ICU (and so Intl.NumberFormat) formats the SHORTEST decimal that reads back as the same double, so
-- 0.145 is the tie "0.145" and rounds to "0.15" (half away from zero), not the binary 0.14499999...
-- Digits are handled as text; a percent is the same digits with the point moved two places.
local function shortest(magnitude)
    if magnitude == 0 then return "0", 0 end
    for precision = 1, 17 do
        local text = string.format("%." .. (precision - 1) .. "e", magnitude)
        if tonumber(text) == magnitude then
            local mantissa, exponent = text:match("^([%d%.]+)e([+-]%d+)$")
            return (mantissa:gsub("%.", "")), tonumber(exponent)
        end
    end
end

-- digits "145", exponent -1 means 1.45e-1 ; returns the fixed text with `places` fractional digits
local function fixed(magnitude, places, shift)
    local digits, exponent = shortest(magnitude)
    exponent = exponent + shift
    -- integer part length = exponent + 1 digits (may be <= 0: leading zeros belong to the fraction)
    local integerLength = exponent + 1
    local all = digits
    if integerLength < 1 then
        all = string.rep("0", 1 - integerLength) .. digits
        integerLength = 1
    end
    if #all < integerLength then all = all .. string.rep("0", integerLength - #all) end
    local cut = integerLength + places
    local kept, rest = all:sub(1, cut), all:sub(cut + 1)
    if #kept < cut then kept = kept .. string.rep("0", cut - #kept) end
    if rest:sub(1, 1) >= "5" and rest ~= "" then
        -- half away from zero on the digit string, carrying through nines
        local chars, index = {}, #kept
        for i = 1, #kept do chars[i] = kept:sub(i, i) end
        while index >= 1 do
            if chars[index] == "9" then chars[index] = "0"; index = index - 1
            else chars[index] = tostring(tonumber(chars[index]) + 1); break end
        end
        kept = table.concat(chars)
        if index == 0 then kept = "1" .. kept; integerLength = integerLength + 1 end
    end
    local integer, fraction = kept:sub(1, integerLength), kept:sub(integerLength + 1)
    integer = integer:gsub("^0+(%d)", "%1")
    return places > 0 and (integer .. "." .. fraction) or integer
end

-- format: "F0".."F6" or "P0".."P6" (default F0)
function Format.number(value, format, locale)
    local kind, digits = (format or "F0"):match("^([FP])([0-6])$")
    assert(kind, "INVALID_NUMBER_FORMAT")
    digits = tonumber(digits)
    local known = knowledge(locale)
    if value ~= value then return "NaN" end
    if value == math.huge then return "∞" elseif value == -math.huge then return "-∞" end
    local negative = value < 0 or (value == 0 and 1 / value < 0)
    local text = fixed(math.abs(value), digits, kind == "P" and 2 or 0)
    if known.decimal ~= "." then text = text:gsub("%.", known.decimal, 1) end
    if kind == "P" then text = text .. (known.percentSpace and NO_BREAK_SPACE or "") .. "%" end
    return (negative and "-" or "") .. text
end

return Format
