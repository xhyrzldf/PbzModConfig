-- Option-label typography (JS 0.3.13 native/NativeRows.js choiceFontFamily/createChoiceTypography).
-- Language names stay in their own script even while the menu is Chinese; the game's rotator would
-- otherwise pick a font from the menu language alone (Korean names render blank in a Chinese menu).
-- Only the face changes: size, outline and material of the row's font are kept.
local ChoiceFont = {}

local function inRange(code, low, high) return code >= low and code <= high end

local VIETNAMESE = {[0x0102] = true, [0x0103] = true, [0x0110] = true, [0x0111] = true, [0x01A0] = true,
    [0x01A1] = true, [0x01AF] = true, [0x01B0] = true}

local function any(text, test)
    if not utf8.len(text) then return false end
    for _, code in utf8.codes(text) do if test(code) then return true end end
    return false
end

function ChoiceFont.family(value, locale)
    local text = value == nil and "" or tostring(value)
    if any(text, function(c) return inRange(c, 0x1100, 0x11FF) or inRange(c, 0x3130, 0x318F) or inRange(c, 0xAC00, 0xD7AF) end) then return "KR" end
    if any(text, function(c) return inRange(c, 0x0400, 0x052F) end) then return "RU" end
    if any(text, function(c) return inRange(c, 0x3400, 0x9FFF) end) then
        return (text == "繁體中文" or locale == "zhHant") and "TC" or "CN"
    end
    if any(text, function(c) return VIETNAMESE[c] or inRange(c, 0x1EA0, 0x1EF9) end) or locale == "vi" then return "VN" end
    if any(text, function(c) return (c < 128 and string.char(c):match("%a") ~= nil) or inRange(c, 0x00C0, 0x024F) end) then return "EN" end
    return ({zhHans = "CN", zhHant = "TC", ko = "KR", ru = "RU"})[locale] or "EN"
end

function ChoiceFont.stylePath(suffix)
    local base = (suffix == "KR" or suffix == "RU" or suffix == "TC" or suffix == "VN")
        and "/Game/PBZContent/UI/Foundation/Text/Textstyle/" or "/Game/PBZContent/UI/UINew/System/Character/"
    local name = "Textstyle_Main_" .. suffix
    return base .. name .. "." .. name .. "_C"
end

local function valid(object) return object ~= nil and object:IsValid() end

-- Default lookup: the text-style blueprint class's default object (JS used
-- SGameAIFunctionLibrary.GetClassDefaultObject on the loaded class).
local function nativeStyle(path)
    local class = StaticFindObject(path)
    if not valid(class) and type(LoadAsset) == "function" then class = LoadAsset(path) end
    assert(valid(class), "CHOICE_FONT_ASSET_MISSING " .. path)
    local style = class:GetCDO()
    assert(valid(style), "CHOICE_FONT_STYLE_MISSING " .. path)
    return style
end

local FONT_FIELDS = {"FontObject", "FontMaterial", "TypefaceFontName", "Size", "LetterSpacing", "SkewAmount",
    "bForceMonospaced", "bMaterialIsStencil", "MonospacedWidth"}
local OUTLINE_FIELDS = {"OutlineSize", "bMiteredCorners", "bSeparateFillAlpha", "bApplyOutlineToDropShadows", "OutlineMaterial"}

-- UE4SS cannot pass a struct userdata back as an argument; build a plain table copy.
local function plainFont(font)
    local result = {}
    for _, name in ipairs(FONT_FIELDS) do result[name] = font[name] end
    local outline = font.OutlineSettings
    if outline ~= nil then
        result.OutlineSettings = {}
        for _, name in ipairs(OUTLINE_FIELDS) do result.OutlineSettings[name] = outline[name] end
        local color = outline.OutlineColor
        if color ~= nil then result.OutlineSettings.OutlineColor = {R = color.R, G = color.G, B = color.B, A = color.A} end
    end
    return result
end

-- FName / UObject values from two reads are different Lua values even when they are equal.
local function same(a, b)
    if rawequal(a, b) then return true end
    local ok, equal = pcall(function()
        if type(a) == "userdata" and type(b) == "userdata" and a.GetAddress and b.GetAddress then
            return a:GetAddress() == b:GetAddress()
        end
        return tostring(a:ToString()) == tostring(b:ToString())
    end)
    return ok and equal == true
end

-- deps.loadStyle(path) -> style object with .Font (injectable for tests); deps.report(code, detail) traces
-- each font actually written (bounded); returns apply(rotator, label, locale).
-- Like the map's font module, a label already in the wanted face is left alone: every refresh of the page
-- used to rewrite the font of every rotator, and with this module on the game crashed while the language
-- options were cycled (2026-11-05 09:33, cause not pinned down).
function ChoiceFont.create(deps)
    deps = deps or {}
    local loadStyle = deps.loadStyle or nativeStyle
    local styles = {}
    local traced = 0
    return function(rotator, label, locale)
        assert(valid(rotator), "CHOICE_ROTATOR_INVALID")
        -- Build 26266538 W_SettingBaseRotator: Construct casts MyText to PBZCommonLocText and stores
        -- it in Text. Both refer to the same widget.
        local function field(name)
            local ok, value = pcall(function() return rotator[name] end)
            if ok and value ~= nil and valid(value) then return value end
        end
        local text = field("Text") or field("MyText")
        assert(valid(text), "CHOICE_TEXT_FONT_UNAVAILABLE")
        local suffix = ChoiceFont.family(label, locale)
        local style = styles[suffix]
        if not valid(style) then
            styles[suffix] = nil
            style = loadStyle(ChoiceFont.stylePath(suffix))
            assert(valid(style) and style.Font and style.Font.FontObject ~= nil, "CHOICE_FONT_ASSET_MISSING " .. suffix)
            styles[suffix] = style
        end
        local font = plainFont(text.Font)
        local source = style.Font
        if same(font.FontObject, source.FontObject) and same(font.TypefaceFontName, source.TypefaceFontName)
            and font.LetterSpacing == source.LetterSpacing then return suffix end
        font.FontObject, font.TypefaceFontName, font.LetterSpacing = source.FontObject, source.TypefaceFontName, source.LetterSpacing
        traced = traced + 1
        if traced <= 40 and deps.report then pcall(deps.report, "CHOICE_FONT_SET", suffix .. " " .. tostring(label)) end
        text:SetFont(font)
        return suffix
    end
end

return ChoiceFont
