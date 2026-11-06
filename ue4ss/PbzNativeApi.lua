-- Builds the `api` table the settings runtime takes (host.enableMenu({api = ...})) from the native
-- modules, one entry per capability. Every entry is created only when its capability is switched on,
-- is unconfirmed in the game until its probe passed, and fails soft: a broken native leaves the
-- plain fallback in place (option font, dialog -> two-step reset, preview pane -> none).
--
--   local api = require("PbzNativeApi").create({capabilities = caps, report = report, scriptsDir = dir,
--                                              wheelPath = optionalOverride, tabIcon = Runtime.textureImporter})
--
-- capabilities used here (all optional, default off):
--   choiceFont     option labels use the font of their own script (JS I07)
--   confirmReset   the game's own yes/no dialog before "reset to defaults" (R02)
--   previewPane    appearance preview and colour before/after swatches next to the list (F, D06)
--   colorWheel     the clickable colour wheel inside that pane (D05); needs previewPane
--   audioFocus     music and ambience duck to 20% while a sound option is previewed (E08)
--   tabIcon        own tab icon, native icon on failure (A06)
--   keySource      "poll": raw key events by polling (needs keyCapture = "session" to be used); resetKey: true
--                  watches the native reset key (R, controller X) on the mod page. See PbzNativeKeys.lua.
--   verboseLog     print every report line (test builds do so on their own), read by PbzSharedHost
local Api = {}

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
end

-- Volume channel values come from the live enum (declaration order is not assumed).
local function volumeEnum(find)
    local values = {}
    for _, package in ipairs({"/Script/ProjectPBZ.", "/Script/SGameAI.", "/Script/SGame.", "/Script/PBZ."}) do
        local enum = try(find, package .. "EAudioVolumeType")
        if valid(enum) then
            pcall(function()
                enum:ForEachName(function(name, value)
                    values[type(name) == "userdata" and name:ToString() or tostring(name)] = value
                end)
            end)
            break
        end
    end
    local function pick(short)
        for key, value in pairs(values) do
            if key == short or key:match("::" .. short .. "$") then return value end
        end
    end
    return {MusicVolume = pick("MusicVolume"), AmbVolume = pick("AmbVolume")}
end

function Api.create(options)
    options = options or {}
    local caps = options.capabilities or {}
    local find = options.find or StaticFindObject
    local report = options.report or function() end
    local function log(code, detail) pcall(report, code, tostring(detail or "")) end
    local api = {}

    if caps.choiceFont == true then
        local fontOptions = {}
        for key, value in pairs(options.choiceFont or {}) do fontOptions[key] = value end
        fontOptions.report = fontOptions.report or log
        local apply = require("PbzChoiceFont").create(fontOptions)
        local disabled = false
        -- Called for every refreshed option row: one failure turns the feature off for the session.
        api.styleChoice = function(rotator, label, locale)
            if disabled then return nil end
            local ok, result = pcall(apply, rotator, label, locale)
            if ok then return result end
            disabled = true
            log("CHOICE_FONT_UNAVAILABLE", result)
        end
    end

    if caps.confirmReset == true then
        local show = require("PbzNativeConfirm").native({report = log, find = find})
        api.confirmReset = function(panel, message, answer, host)
            -- The probe (p52) keeps the dialog receiver on the panel's root widget.
            local root = try(function() return panel.WidgetTree.RootWidget end)
            if valid(root) and try(function() return root.AddChild ~= nil end) then host = root end
            return show(panel, message, answer, host)
        end
    end

    if caps.previewPane == true then
        local Pane = require("PbzNativePreviewPane")
        local wheelPath = options.wheelPath or (options.scriptsDir and (options.scriptsDir .. "/color-wheel.png")) or nil
        api.previewPane = function(context)
            local nativeOptions
            if caps.colorWheel == true and wheelPath then
                local button = try(FindFirstOf, "W_SettingBaseButton_C")
                local buttonClass = valid(button) and try(function() return button:GetClass() end) or nil
                if buttonClass then nativeOptions = {wheel = true, wheelPath = wheelPath, buttonClass = buttonClass} end
            end
            return Pane.create({panel = context.panel, details = context.details, words = context.words,
                report = context.report, api = Pane.nativeApi(nativeOptions)})
        end
    end

    if caps.audioFocus == true then
        local Audio = require("PbzPreviewAudio")
        api.audioFocus = function(panel)
            local context = try(FindFirstOf, "PlayerController")
            if not valid(context) then context = panel end
            return Audio.nativeApi({find = find, context = context, enum = volumeEnum(find)})
        end
    end

    -- Key events and the native reset key (see PbzNativeKeys): polling only. The hook and key-bind routes
    -- were removed in the review of 2026-11-05; asking for them is reported and ignored.
    if caps.keySource == "poll" or (caps.resetKey and not caps.keySource) then
        api.keySource = require("PbzNativeKeys").create({resetKey = caps.resetKey, report = log, find = find})
    elseif caps.keySource then
        log("KEY_SOURCE_REMOVED", tostring(caps.keySource) .. ": only keySource = \"poll\" is supported")
    end

    if caps.tabIcon == true and options.tabIcon and options.scriptsDir then
        api.tabIcon = options.tabIcon(options.scriptsDir .. "/modconfig-icon.png")
    end

    return api
end

return Api
