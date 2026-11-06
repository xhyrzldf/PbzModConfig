-- UE4SS port adapted from the existing native-menu prototype.
local Widgets = require("PbzNativeWidgets")
local Tabs = require("PbzNativeTabs")
local Menu = require("PbzNativeMenu")
local BindingRules = require("PbzBindingRules")

-- Optional collaborators. A genuinely missing module disables the features that need
-- it (colour/sound rows, shared value rules); a module that fails to load is an error.
local function optional(name)
    local ok, result = pcall(require, name)
    if ok then return result end
    if tostring(result):find("module '" .. name .. "' not found", 1, true) then return nil end
    error(result, 0)
end
local Core = optional("PbzConfigCore")
local Editors = Core and optional("PbzEditors") or nil
local Audio = optional("PbzPreviewAudio")
local Selection = optional("PbzNativeSelection")
local Navigation = optional("PbzNavigation")
local Visual = Core and optional("PbzVisualPreview") or nil
local Confirm = optional("PbzNativeConfirm")
local Projection = optional("PbzLegacyProjection")
local ActionBar = optional("PbzNativeActionBar")
local Events = optional("PbzNativeEvents")

local Runtime = {}
local SLOT = "__PBZ_MODCONFIG_RUNTIME_V1__"
-- Expanded mod sections live for the whole game process (JS keeps them in a module-level Map), so a
-- runtime restart after a provider change does not collapse what the player had open.
local EXPANDED_SLOT = "__PBZ_MODCONFIG_EXPANDED_V1__"
local function expandedSections()
    local value = rawget(_G, EXPANDED_SLOT)
    if type(value) ~= "table" then value = {}; rawset(_G, EXPANDED_SLOT, value) end
    return value
end
local TAG = "PbzModConfigRuntime/1"

local ENTRY_TYPES = {header = true, toggle = true, choice = true, number = true, action = true, keybind = true}
if Core and Editors then ENTRY_TYPES.color, ENTRY_TYPES.sound = true, true end

-- Used when the host supplies no (or a partial) translation table.
local DEFAULT_WORDS = {
    unavailable = {zhHans = "暂不可用", en = "Unavailable"},
    editRejected = {zhHans = "未能应用，请重试或取消。", en = "Couldn't apply this change. Retry or cancel."},
    failed = {zhHans = "保存失败，当前更改尚未写入文件。", en = "Couldn't save your changes."},
    pending = {zhHans = "正在保存…", en = "Saving…"},
    off = {zhHans = "关闭", en = "Off"}, on = {zhHans = "开启", en = "On"},
    pressKey = {zhHans = "按下按键…", en = "Press a key…"}, unbound = {zhHans = "未绑定", en = "Unbound"},
    clearBinding = {zhHans = "清除绑定", en = "Clear binding"},
    bindingConflict = {zhHans = "此按键已被本模组使用。", en = "This binding is already used by this mod."},
    cancel = {zhHans = "取消", en = "Cancel"}, applyColor = {zhHans = "确认颜色", en = "Apply color"},
    red = {zhHans = "红", en = "Red"}, green = {zhHans = "绿", en = "Green"}, blue = {zhHans = "蓝", en = "Blue"},
    alpha = {zhHans = "透明度", en = "Opacity"}, preview = {zhHans = "试听", en = "Preview"},
    stop = {zhHans = "停止", en = "Stop"}, reset = {zhHans = "恢复默认", en = "Reset to defaults"},
    confirm = {zhHans = "恢复此模组的默认设置？", en = "Reset this mod's settings to their defaults?"},
    expand = {zhHans = "展开", en = "Expand"}, collapse = {zhHans = "收起", en = "Collapse"},
    author = {zhHans = "作者：", en = "By "},
    version = {zhHans = "版本", en = "Version"}, empty = {zhHans = "暂无可配置的模组", en = "No mod settings available"},
}

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function resolve(value, options)
    if options.localeResolver then return tostring(options.localeResolver(value, options.locale or "zhHans") or "") end
    if value == nil then return "" end
    if type(value) ~= "table" then return tostring(value) end
    if value.zhHans or value["zh-CN"] or value.zh or value.en then
        return value.zhHans or value["zh-CN"] or value.zh or value.en
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    return value[keys[1]] or ""
end

local function matches(rule, values)
    return rule == nil or values[rule.key] == rule.equals
end

local function valueValid(entry, value)
    if entry.type == "header" or entry.type == "action" then return true end
    if Core and Core.VALUE_TYPES[entry.type] then
        -- One rule set for every control: the same functions the JavaScript provider uses.
        local ok, problem = pcall(Core.valueError, entry, value)
        return ok and problem == nil
    end
    if entry.type == "toggle" then return type(value) == "boolean" end
    if entry.type == "keybind" then return BindingRules.bindingError(entry, value) == nil end
    if entry.type == "choice" then
        for _, option in ipairs(entry.options or {}) do if option.value == value then return true end end
        return false
    end
    if entry.type == "number" then
        if not finite(value) or not finite(entry.min) or not finite(entry.max) or not finite(entry.step)
            or entry.step <= 0 or value < entry.min or value > entry.max then return false end
        local units = (value - entry.min) / entry.step
        return math.abs(units - math.floor(units + 0.5)) <= 1e-7
    end
    return false
end

local PERSISTENCE_STATES = {saved = true, pending = true, failed = true}

-- JS Framework.read: a safe, non-negative revision that never goes back, exactly the known values,
-- each of them valid, and a known save state.
local function read(provider, previousRevision)
    local snapshot = provider.read()
    assert(type(snapshot) == "table" and snapshot.ok ~= false, snapshot and snapshot.error or "PROVIDER_READ_FAILED")
    assert(finite(snapshot.revision) and snapshot.revision >= 0 and snapshot.revision % 1 == 0
        and snapshot.revision <= 9007199254740991 and type(snapshot.values) == "table", "INVALID_PROVIDER_SNAPSHOT")
    assert(previousRevision == nil or snapshot.revision >= previousRevision, "PROVIDER_REVISION_REGRESSED")
    local values, known = {}, {}
    for _, entry in ipairs(provider.entries) do
        if entry.type ~= "header" and entry.type ~= "action" then
            known[entry.key] = true
            local value = snapshot.values[entry.key]
            assert(valueValid(entry, value), "INVALID_PROVIDER_VALUE " .. entry.key)
            values[entry.key] = value
        end
    end
    for key in pairs(snapshot.values) do assert(known[key], "UNKNOWN_PROVIDER_VALUE " .. tostring(key)) end
    local persistence = snapshot.persistence or {}
    assert(persistence.state == nil or PERSISTENCE_STATES[persistence.state], "INVALID_PROVIDER_PERSISTENCE")
    return {revision = snapshot.revision, values = values,
        persistence = {state = persistence.state, error = persistence.error}}
end

-- Controller buttons as players call them; JS showed the raw EKeys name ("Gamepad_LeftShoulder").
-- {simplified Chinese, traditional Chinese, every other language}
local GAMEPAD_NAMES = {
    Gamepad_FaceButton_Bottom = "A", Gamepad_FaceButton_Right = "B", Gamepad_FaceButton_Left = "X", Gamepad_FaceButton_Top = "Y",
    Gamepad_LeftShoulder = "LB", Gamepad_RightShoulder = "RB", Gamepad_LeftTrigger = "LT", Gamepad_RightTrigger = "RT",
    Gamepad_LeftThumbstick = {"左摇杆按下", "左搖桿按下", "Left Stick Press"},
    Gamepad_RightThumbstick = {"右摇杆按下", "右搖桿按下", "Right Stick Press"},
    Gamepad_DPad_Up = {"十字键上", "十字鍵上", "D-Pad Up"}, Gamepad_DPad_Down = {"十字键下", "十字鍵下", "D-Pad Down"},
    Gamepad_DPad_Left = {"十字键左", "十字鍵左", "D-Pad Left"}, Gamepad_DPad_Right = {"十字键右", "十字鍵右", "D-Pad Right"},
    Gamepad_Special_Left = {"视图键", "檢視鍵", "View"}, Gamepad_Special_Right = {"菜单键", "選單鍵", "Menu"},
    Gamepad_LeftStick_Up = {"左摇杆上", "左搖桿上", "Left Stick Up"}, Gamepad_LeftStick_Down = {"左摇杆下", "左搖桿下", "Left Stick Down"},
    Gamepad_LeftStick_Left = {"左摇杆左", "左搖桿左", "Left Stick Left"}, Gamepad_LeftStick_Right = {"左摇杆右", "左搖桿右", "Left Stick Right"},
    Gamepad_RightStick_Up = {"右摇杆上", "右搖桿上", "Right Stick Up"}, Gamepad_RightStick_Down = {"右摇杆下", "右搖桿下", "Right Stick Down"},
    Gamepad_RightStick_Left = {"右摇杆左", "右搖桿左", "Right Stick Left"}, Gamepad_RightStick_Right = {"右摇杆右", "右搖桿右", "Right Stick Right"},
}
local function gamepadName(key, locale)
    local name = GAMEPAD_NAMES[key]
    if type(name) == "table" then return locale == "zhHans" and name[1] or locale == "zhHant" and name[2] or name[3] end
    return name
end

local function format(value, entry, options, word, locale)
    if entry.type == "number" then
        local kind, digits = (entry.format or "F0"):match("^([FP])([0-6])$")
        assert(kind, "INVALID_NUMBER_FORMAT")
        -- capabilities.localizedNumbers: the separators and spacing Intl.NumberFormat gives the game language
        if options.formatNumber then return options.formatNumber(value, entry.format or "F0", locale or "zhHans") end
        return string.format("%." .. digits .. "f", value * (kind == "P" and 100 or 1)) .. (kind == "P" and "%" or "")
    end
    if entry.type == "choice" or entry.type == "sound" then
        for _, option in ipairs(entry.options) do if option.value == value then return resolve(option.label, options) end end
    end
    if entry.type == "keybind" and (value == nil or value == "") then return word("unbound") end
    if entry.type == "keybind" and gamepadName(value, locale) then return gamepadName(value, locale) end
    return value == nil and "" or tostring(value)
end

local function livePanel(panel)
    if not valid(panel) then return false end
    local name = panel:GetFullName()
    if name:find("Default__", 1, true) or name:find("TRASHCLASS_", 1, true) or not valid(panel:GetWorld()) then return false end
    local cursor, seen = panel, {}
    for _ = 1, 24 do
        if not valid(cursor) or seen[cursor:GetAddress()] then break end
        seen[cursor:GetAddress()] = true
        local visibility = cursor:GetVisibility()
        if visibility == Widgets.V.Collapsed or visibility == Widgets.V.Hidden then return false end
        local parent = cursor:GetParent()
        if valid(parent) then cursor = parent
        else
            local outer = cursor:GetOuter()
            local owner = valid(outer) and outer:GetOuter() or nil
            if not Widgets.is(owner, "UserWidget") then break end
            cursor = owner
        end
    end
    return true
end

Runtime.POLL_MS, Runtime.FAST_POLL_MS = 500, 50
-- After LoadMapPost the page stays suspended this long before it touches any panel again.
Runtime.RESUME_SECONDS = 1.0
-- A (re)started runtime waits as well: a reload may land in the middle of a load (review 2026-11-05).
Runtime.START_WAIT_SECONDS = 1.0
local WORLD_SLOT = "__PBZ_MODCONFIG_WORLD_V1__"

local function readyPanel(panel)
    local tabs = panel.W_OverlayTabList_C
    if not valid(tabs) or not valid(panel.ListView_Settings) or not valid(panel.Details_Settings)
        or not valid(panel.WidgetSwitcher_65) then return false end
    local collections, ids = panel.SettingCollections, tabs.TabButtonIDs
    if collections == nil or ids == nil or tabs.PreregisteredTabInfoArray == nil then return false end
    local count = collections:GetArrayNum()
    if count <= 0 or ids:GetArrayNum() ~= count or tabs.PreregisteredTabInfoArray:GetArrayNum() <= 0 then return false end
    -- Reading an absent TArray element grows it in UE4SS 1195. Check every
    -- count first, then wait for native registration to create the first button.
    return valid(collections[1]) and valid(tabs:GetTabButtonBaseByID(ids[1]))
end

local function equalModel(left, right)
    for key, value in pairs(left) do
        if key ~= "options" and key ~= "baseRevision" and right[key] ~= value then return false end
    end
    for key, value in pairs(right) do
        if key ~= "options" and key ~= "baseRevision" and left[key] ~= value then return false end
    end
    local a, b = left.options or {}, right.options or {}
    if #a ~= #b then return false end
    for index, option in ipairs(a) do
        if option.value ~= b[index].value or option.label ~= b[index].label then return false end
    end
    return true
end

-- api.tabIcon helper: imports a PNG from disk as the tab icon (JS does the same from the pak's content
-- directory). Needs capabilities.tabIcon = true; any failure leaves the native icon in place.
function Runtime.textureImporter(path)
    assert(type(path) == "string" and path ~= "", "TEXTURE_PATH_REQUIRED")
    return function(panel)
        local library = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
        assert(valid(library), "TEXTURE_LIBRARY_MISSING")
        local texture = library:ImportFileAsTexture2D(panel, path)
        assert(valid(texture), "PNG_IMPORT_RETURNED_NULL")
        return texture
    end
end

function Runtime.start(providers, options)
    options = options or {}
    assert(type(providers) == "table", "PROVIDERS_REQUIRED")
    -- A provider with controls this page cannot show is offered its basic projection (JS
    -- Compatibility.compatibleDescriptor): hidden values stay with the owner, dependants are left out too.
    local projected = {}
    if Projection then
        local shown = {}
        for index, provider in ipairs(providers) do
            if Projection.needed(provider, ENTRY_TYPES) then
                shown[index] = Projection.project(provider, ENTRY_TYPES)
                projected[#projected + 1] = tostring(provider.modId)
            else shown[index] = provider end
        end
        providers = shown
    end
    local ids = {}
    for _, provider in ipairs(providers) do
        assert(type(provider.modId) == "string" and provider.modId:match("^[A-Za-z][A-Za-z0-9_.-]*$")
            and not ids[provider.modId], "INVALID_OR_DUPLICATE_PROVIDER")
        assert(type(provider.entries) == "table" and type(provider.groups) == "table"
            and type(provider.read) == "function" and type(provider.apply) == "function"
            and type(provider.flush) == "function", "INVALID_PROVIDER_API")
        ids[provider.modId] = true
        local groups, keys = {}, {}
        for _, group in ipairs(provider.groups) do
            assert(group.id and not groups[group.id], "INVALID_PROVIDER_GROUP")
            groups[group.id] = true
        end
        for _, entry in ipairs(provider.entries) do
            assert(type(entry.key) == "string" and not keys[entry.key], "INVALID_PROVIDER_ENTRY")
            assert(not entry.group or groups[entry.group], "UNKNOWN_PROVIDER_GROUP")
            assert(ENTRY_TYPES[entry.type], "UNSUPPORTED_PROVIDER_ENTRY " .. tostring(entry.type))
            keys[entry.key] = true
        end
    end
    local previous = rawget(_G, SLOT)
    assert(not previous or (previous.tag == TAG and type(previous.stop) == "function"), "RUNTIME_SLOT_ALREADY_OWNED")
    if previous then assert(previous.stop() ~= false, "PREVIOUS_RUNTIME_STOP_FAILED") end
    local runtime = {tag = TAG, stopped = false, closed = false, panels = {}, failed = {}}
    rawset(_G, SLOT, runtime)
    local report = options.report or function(code, detail)
        print("[PbzModConfig] " .. code .. " " .. tostring(detail) .. "\n")
    end
    local function log(code, detail)
        local ok, err = pcall(report, code, detail)
        if not ok then print("[PbzModConfig] REPORT_FAILED " .. tostring(err) .. "\n") end
    end

    -- Capabilities that depend on native behaviour not yet confirmed in the game.
    -- Every one is off by default and has a working fallback.
    local capabilities, api = options.capabilities or {}, options.api or {}
    -- Bindings are edited only by the polled capture session. Without it a binding is shown read-only:
    -- the InputKeySelector row (struct-parameter delegate) was never verified in game and is not a
    -- fallback (review 2026-11-05).
    local keyCapture = capabilities.keyCapture == "session" and "session" or "off"
    local keySource = type(api.keySource) == "table" and api.keySource or nil
    local hasKeySource = keySource ~= nil and type(keySource.subscribe) == "function"
    if keyCapture == "session" and not hasKeySource then
        log("KEY_CAPTURE_SOURCE_MISSING", "session capture needs api.keySource; bindings are read-only")
        keyCapture = "off"
    end
    if keyCapture == "session" and keySource.anyKey == false then
        log("KEY_CAPTURE_SOURCE_LIMITED", "this key source cannot see arbitrary keys; bindings are read-only")
        keyCapture = "off"
    end
    -- JS-style navigation (JS NativeMenu.key/analog) needs raw key events; the default route relies on
    -- native Slate/CommonUI focus navigation inside the ScrollBox instead.
    local customNavigation = capabilities.navigation == "custom" and Selection ~= nil and Navigation ~= nil
    if customNavigation and not hasKeySource then
        log("NAVIGATION_SOURCE_MISSING", "custom navigation needs api.keySource; using native navigation")
        customNavigation = false
    end
    if customNavigation and keySource.consumes ~= true then
        -- An observer cannot swallow the event: the native focus navigation moves as well.
        log("NAVIGATION_SOURCE_OBSERVES_ONLY", tostring(keySource.name))
    end
    -- The native "reset" key (JS wraps handleResetKeyPressed) resets the selected row's mod.
    local resetKey = capabilities.resetKey ~= nil and capabilities.resetKey ~= false
        and keySource ~= nil and type(keySource.subscribeReset) == "function"
    local now = options.now or os.clock
    -- The game language right now (JS state.locale). The resolver answers a table keyed by every game
    -- language with the entry of the current one, which is how the page learns the language without
    -- a second hook into the locale monitor.
    local LOCALE_PROBE = {zhHans = "zhHans", zhHant = "zhHant", en = "en", ko = "ko", ru = "ru", ["es-ES"] = "es-ES",
        ["es-419"] = "es-419", vi = "vi"}
    local function currentLocale()
        if options.locale then return options.locale end
        if options.localeResolver then
            local ok, value = pcall(options.localeResolver, LOCALE_PROBE, "zhHans")
            if ok and type(value) == "string" and value ~= "" then return value end
        end
        return "zhHans"
    end
    if capabilities.localizedNumbers == true and options.formatNumber == nil then
        local loaded, module = pcall(require, "PbzNumberFormat")
        if loaded then options.formatNumber = module.number else log("NUMBER_FORMAT_UNAVAILABLE", module) end
    end
    local DEFER_FLUSH_SECONDS = 1.5
    -- Same signature as UE4SS ExecuteInGameThreadWithDelay(ms, callback); Editors calls (callback, ms).
    local scheduleRaw = options.schedule or ExecuteInGameThreadWithDelay
    -- A timer set in one world never runs in the next one, nor while a world loads (review 2026-11-05).
    local schedule = scheduleRaw and function(callback, ms)
        local born = runtime.worldChanges or 0
        return scheduleRaw(ms, function()
            if runtime.stopped or runtime.suspended or (runtime.worldChanges or 0) ~= born then return end
            callback()
        end)
    end or nil
    runtime.scheduleForTest = schedule
    local cancelTimer = options.cancel or CancelDelayedAction

    for _, id in ipairs(projected) do log("PROVIDER_PROJECTED", id) end

    local function word(key, fallback)
        return resolve(options.words and options.words[key] or fallback or DEFAULT_WORDS[key], options)
    end

    local playback = Audio and Audio.createPlayback({report = log}) or nil
    local inlineConfirm = Confirm and Confirm.inline({now = now, windowSeconds = 4}) or nil
    local retire
    -- A native failure of the page's own widgets (JS NativeMenu.fail): the page fails once, with a
    -- bounded detail, is never rebuilt for this panel, and nothing touches its widgets again.
    local function faultPage(state, code, err)
        if state.faulted then return end
        state.faulted = true
        runtime.failed[state.address] = true
        local detail = tostring(err)
        if #detail > 160 then detail = detail:sub(1, 160) end
        log(code, detail)
        ExecuteInGameThread(function()
            -- A world change forgets the page meanwhile; nothing is closed while a world loads.
            if runtime.stopped or runtime.suspended then return end
            if runtime.panels[state.address] == state and not state.retired then retire(state.address, state) end
        end)
    end

    local disposePane
    -- Select the first native tab. true when the mod tab is no longer selected (or the panel is gone);
    -- false plus a reason when the tab list refused. A tab list without the selection API is left alone.
    local function returnToNativeTab(state)
        local panel = state.panel
        if not valid(panel) then return true end
        local tabs = panel.W_OverlayTabList_C
        if not valid(tabs) then return true end
        local ok, reason = pcall(function()
            local function has(name)
                local found, method = pcall(function() return tabs[name] end)
                return found and (type(method) == "function" or (type(method) == "userdata" and method ~= nil))
            end
            if not (has("SelectTabByID") and has("GetTabIdAtIndex") and has("GetSelectedTabId")) then
                error("NATIVE_TAB_API_MISSING", 0)
            end
            -- SelectTabByID(TabNameID, bSuppressClickFeedback): two parameters in game (session 1).
            tabs:SelectTabByID(tabs:GetTabIdAtIndex(0), true)
            local function idText(id) return type(id) == "string" and id or id:ToString() end
            if idText(tabs:GetSelectedTabId()) == idText(state.tab.id) then error("STILL_SELECTED", 0) end
        end)
        if ok then return true end
        if reason == "NATIVE_TAB_API_MISSING" then return true end
        return false, tostring(reason)
    end
    -- True once the page's resources are released. A failed step is kept (state.menu, state.tab)
    -- so a later call retries it; the caller must not forget the panel on false.
    local function close(state)
        local clean = true
        if state.records then
            for _, record in ipairs(state.records) do
                if record.dirtySince then
                    record.dirtySince = nil
                    local ok, err = pcall(record.provider.flush)
                    if not ok then log("PROVIDER_FLUSH_FAILED", record.provider.modId .. " " .. tostring(err)) end
                end
            end
        end
        if not disposePane(state) then clean = false end
        if state.editors then
            local ok, err = pcall(state.editors.close)
            if not ok then log("EDITORS_CLOSE_FAILED", err) end
        end
        if state.keyRelease then
            local ok, released = pcall(state.keyRelease)
            if ok and released ~= false then state.keyRelease = nil
            else
                clean = false
                log("KEY_SOURCE_RELEASE_FAILED", ok and "incomplete release" or released)
            end
        end
        -- JS loader.stop(): a page that is still showing must hand the panel back to the first native tab
        -- before its collection and tab are removed.
        if state.menu and state.tab and state.menu.active and not state.menu.disposed and not state.returnedToNative then
            local returned, reason = returnToNativeTab(state)
            if returned then state.returnedToNative = true
            else
                -- Nothing has been torn down yet: the page stays whole until the player is on a native tab.
                log("NATIVE_TAB_RETURN_REQUIRED", reason)
                return false
            end
        end
        if state.menu then
            local ok, released = pcall(state.menu.dispose)
            if ok and released ~= false then state.menu = nil
            else
                clean = false
                log("MENU_DISPOSE_FAILED", ok and "incomplete release" or released)
            end
        end
        if state.tab then
            if valid(state.panel) and valid(state.panel.W_OverlayTabList_C) then
                local current = state.panel.W_OverlayTabList_C:GetTabButtonBaseByID(state.tab.id)
                if valid(current) and valid(state.tab.button) and current:GetAddress() == state.tab.button:GetAddress() then
                    local ok, err = pcall(state.tab.detach)
                    if ok then state.tab = nil
                    else
                        clean = false
                        log("TAB_DETACH_FAILED", err)
                    end
                else
                    log("TAB_OWNERSHIP_CHANGED", state.address)
                    state.tab = nil
                end
            else state.tab = nil end
        end
        return clean
    end

    local function entryUsable(record, key, value)
        local snapshot = record.snapshot
        if not snapshot then return false end
        for _, entry in ipairs(record.provider.entries) do
            if entry.key == key then
                return snapshot.values[key] == value and matches(entry.enabledWhen, snapshot.values)
                    and matches(entry.visibleWhen, snapshot.values)
            end
        end
        return false
    end

    local function refreshRecords(state)
        for _, record in ipairs(state.records) do
            local provider = record.provider
            local ok, snapshot = pcall(read, provider, record.revision)
            record.readFailed = not ok
            if ok then
                record.snapshot, record.revision = snapshot, snapshot.revision
                if record.errorKind == "read" then
                    record.error, record.errorKind = nil, nil
                end
                if playback then playback.reconcile(provider, function(key, value) return entryUsable(record, key, value) end) end
            else
                if playback then playback.fault(provider) end
                if record.error ~= tostring(snapshot) then log("PROVIDER_READ_FAILED", provider.modId .. " " .. tostring(snapshot)) end
                record.error, record.errorKind = tostring(snapshot), "read"
            end
            if type(provider.consumeAsyncError) == "function" then
                local fetched, failure = pcall(provider.consumeAsyncError)
                if fetched and failure then
                    record.error, record.errorKind, record.errorCode = tostring(failure), "apply", nil
                    log("PROVIDER_ASYNC_FAILED", provider.modId .. " " .. tostring(failure))
                elseif not fetched then log("PROVIDER_ASYNC_POLL_FAILED", failure) end
            end
        end
    end

    local function modelsFor(state)
        local models, byId = {}, {}
        local function append(model) models[#models + 1] = model end
        local editors = state.editors
        local feedback = editors and editors.feedback() or nil
        for _, record in ipairs(state.records) do
            local provider, snapshot = record.provider, record.snapshot
            local title = resolve(provider.displayName or provider.modId, options)
            local open = expandedSections()[provider.modId] == true
            local version = provider.modVersion ~= nil and tostring(provider.modVersion) or ""
            local persistence = snapshot and snapshot.persistence or {}
            local failure = record.error or (persistence.state == "failed" and (persistence.error or "SAVE_FAILED") or nil)
            local pending = persistence.state == "pending"
            local own = feedback and feedback.id and feedback.id:sub(1, #provider.modId + 1) == provider.modId .. "/"
            -- JS details(): edit feedback for the row first, then the page's save state.
            local pageWarning = ""
            if failure then
                if record.errorKind == "read" then pageWarning = word("unavailable")
                elseif record.errorKind == "apply" then
                    pageWarning = word(record.errorCode == "BINDING_CONFLICT" and "bindingConflict" or "editRejected")
                else pageWarning = word("failed") end
            elseif pending then pageWarning = word("pending") end
            local first = #models + 1
            -- Like JS: the title is an action row whose button expands or collapses the mod.
            append({id = provider.modId .. "/@title", type = "action", section = true, expanded = open, synthetic = true,
                label = title .. (version ~= "" and "  ·  " .. version or ""), title = title,
                description = version ~= "" and (word("version") .. " " .. version) or "",
                buttonLabel = word(open and "collapse" or "expand"), expandLabel = word("expand"), collapseLabel = word("collapse"),
                providerId = provider.modId, ownerToken = provider, visible = true, enabled = true, warning = pageWarning,
                locale = currentLocale()})
            if not open then goto nextRecord end
            local status = pageWarning
            if not failure and own then status = word(feedback.code == "BINDING_CONFLICT" and "bindingConflict" or "editRejected") end
            -- With a working details pane the state is shown there (JS); the row is only a fallback.
            append({id = provider.modId .. "/@status", type = "header", label = status,
                visible = not state.detailsAvailable and (failure ~= nil or own == true or pending)})
            if snapshot then
                local groups = {}
                for index, group in ipairs(provider.groups) do groups[#groups + 1] = {group = group, index = index} end
                table.sort(groups, function(a, b)
                    local left, right = a.group.order or 0, b.group.order or 0
                    return left < right or (left == right and a.index < b.index)
                end)
                -- UE4SS addition: entry.gamepadKey names the controller binding shown on the same row as this
                -- keyboard binding (session capture only; both values stay stored separately).
                local companionOf, companions = {}, {}
                if editors and keyCapture == "session" then
                    local byKey = {}
                    for _, entry in ipairs(provider.entries) do byKey[entry.key] = entry end
                    for _, entry in ipairs(provider.entries) do
                        local other = entry.type == "keybind" and type(entry.gamepadKey) == "string" and byKey[entry.gamepadKey] or nil
                        if other and other ~= entry and other.type == "keybind" and other.gamepadKey == nil
                            and not companions[entry.key] and not companionOf[other.key] and not companions[other.key] then
                            companionOf[entry.key], companions[other.key] = other, true
                        end
                    end
                end
                local function entries(groupId)
                    local anyVisible = false
                    for _, entry in ipairs(provider.entries) do
                        if entry.group == groupId and not companions[entry.key] then
                            local value = snapshot.values[entry.key]
                            local visible = matches(entry.visibleWhen, snapshot.values)
                            anyVisible = anyVisible or visible
                            local model = {id = provider.modId .. "/" .. entry.key, providerId = provider.modId, key = entry.key,
                                ownerToken = provider, type = entry.type, label = resolve(entry.label, options),
                                description = resolve(entry.description, options),
                                value = value, displayValue = format(value, entry, options, word, currentLocale()), control = entry,
                                baseRevision = snapshot.revision, min = entry.min, max = entry.max, step = entry.step,
                                visible = visible, enabled = not record.readFailed and matches(entry.enabledWhen, snapshot.values),
                                disabledReason = resolve(entry.disabledReason, options), locale = currentLocale(),
                                buttonLabel = resolve(entry.buttonLabel or entry.label, options),
                                captureLabel = entry.captureLabel and resolve(entry.captureLabel, options) or word("pressKey"),
                                unboundLabel = entry.unboundLabel and resolve(entry.unboundLabel, options) or word("unbound"),
                                clearLabel = entry.clearLabel and resolve(entry.clearLabel, options) or word("clearBinding")}
                            local other = companionOf[entry.key]
                            if other then
                                local otherValue = snapshot.values[other.key]
                                model.pair = {key = other.key, control = other, value = otherValue}
                                local shown = {}
                                if value ~= nil and value ~= "" then shown[#shown + 1] = model.displayValue end
                                if otherValue ~= nil and otherValue ~= "" then
                                    shown[#shown + 1] = format(otherValue, other, options, word, currentLocale())
                                end
                                if #shown > 0 then model.displayValue = table.concat(shown, " / ") end
                            end
                            if entry.type == "number" then
                                model.minDisplayValue, model.maxDisplayValue = format(entry.min, entry, options, word, currentLocale()), format(entry.max, entry, options, word, currentLocale())
                            elseif entry.type == "toggle" then
                                model.options = {{value = false, label = word("off")}, {value = true, label = word("on")}}
                            elseif entry.type == "choice" or entry.type == "sound" then
                                model.options = {}
                                for _, option in ipairs(entry.options) do model.options[#model.options + 1] = {value = option.value, label = resolve(option.label, options)} end
                            end
                            if entry.type == "keybind" and keyCapture ~= "session" then
                                model.type, model.buttonLabel, model.enabled = "action", model.displayValue, false
                                if model.disabledReason == nil or model.disabledReason == "" then model.disabledReason = word("unavailable") end
                            end
                            byId[model.id] = model
                            if editors then
                                for _, expanded in ipairs(editors.rows(model)) do append(expanded) end
                            else append(model) end
                        end
                    end
                    return anyVisible
                end
                entries(nil)
                for _, item in ipairs(groups) do
                    local group = item.group
                    local heading = {id = provider.modId .. "/@group/" .. group.id, type = "header", label = resolve(group.label, options)}
                    append(heading)
                    heading.visible = entries(group.id)
                end
                if type(provider.reset) == "function" then
                    local armed = inlineConfirm ~= nil and inlineConfirm.armed(provider.modId)
                    append({id = provider.modId .. "/@reset", type = "action", label = word("reset"),
                        buttonLabel = armed and word("confirm") or word("reset"),
                        description = title, reset = true, providerId = provider.modId, ownerToken = provider,
                        baseRevision = snapshot.revision, visible = true, enabled = not record.readFailed, locale = currentLocale()})
                end
            end
            for index = first + 1, #models do
                local model = models[index]
                if model.type ~= "header" then
                    local mine = feedback and feedback.id and (feedback.id == model.id or feedback.id == model.parentId)
                    model.warning = mine and word(feedback.code == "BINDING_CONFLICT" and "bindingConflict" or "editRejected") or pageWarning
                end
            end
            ::nextRecord::
        end
        if #state.records == 0 then append({id = "@empty", type = "header", label = word("empty"), visible = true}) end
        return models, byId
    end

    local updatePage, changed, rebuildPage, menuHandlers, tabSelected
    -- Right-hand preview pane (capability previewPane, off by default): the provider's appearance
    -- preview and the colour editor's before/after swatches and wheel. api.previewPane(ctx) takes
    -- {panel, details, words, report} and returns {update(model, ctx), hide(), dispose()}; the pane owns
    -- every widget it creates. A failing pane is reported once and never rebuilt for this page.
    local function paneEnabled()
        return capabilities.previewPane == true and type(api.previewPane) == "function"
    end
    local function paneAccepts(state)
        return function()
            local menu = state.menu
            return menu ~= nil and not menu.disposed and menu.active == true and not menu.covered and not state.confirming
        end
    end
    local function syncPane(state)
        if not paneEnabled() or state.paneFailed or not state.menu or not state.menu.hasDetails then return end
        local menu = state.menu
        local model = menu.selectedModel()
        local edit = state.editors and state.editors.colorEdit() or nil
        local record = (edit and state.providers[edit.providerId])
            or (model and model.providerId and state.providers[model.providerId]) or nil
        local accepts = paneAccepts(state)
        local snapshot = record and record.snapshot
        local signature = table.concat({tostring(accepts()), model and model.id or "-", edit and (edit.id .. "=" .. edit.value) or "-",
            snapshot and tostring(snapshot.revision) or "-", tostring(record and record.readFailed or false)}, "|")
        if state.pane and state.paneSignature == signature then return end
        if not state.pane then
            local wanted = edit ~= nil
            if not wanted and Visual and record and model and not model.section and model.key then
                state.visual = state.visual or Visual.create({report = log, locale = currentLocale})
                wanted = state.visual.has(record, model.key)
            end
            if not wanted then state.paneSignature = signature; return end
            local built, pane = pcall(api.previewPane, {panel = state.panel, details = menu.details, words = word, report = log})
            if not (built and type(pane) == "table" and type(pane.update) == "function" and type(pane.dispose) == "function") then
                state.paneFailed = true
                log("PREVIEW_PANE_UNAVAILABLE", built and "invalid pane controller" or pane)
                return
            end
            state.pane = pane
        end
        if Visual and not state.visual then
            state.visual = Visual.create({report = log, locale = currentLocale})
        end
        local updated, kept = pcall(state.pane.update, model, {record = record, colorEdit = edit,
            committed = edit and snapshot and snapshot.values[edit.key] or nil, visual = state.visual,
            acceptsInput = accepts, pickColor = function(value)
                return state.editors ~= nil and state.editors.pickColor(value) or false
            end})
        state.paneSignature = signature
        if not updated or kept == false then
            state.paneFailed = true
            if not updated then log("PREVIEW_PANE_FAILED", kept) end
            disposePane(state)
        end
    end
    -- Releases the pane and the open appearance preview. False when the pane could not be released.
    disposePane = function(state)
        local clean = true
        if state.pane then
            local ok, err = pcall(state.pane.dispose)
            if ok then state.pane = nil
            else
                clean = false
                log("PREVIEW_PANE_DISPOSE_FAILED", err)
            end
        end
        state.paneSignature = nil
        if state.visual then
            local ok, err = pcall(state.visual.dispose)
            if not ok then log("VISUAL_PREVIEW_DISPOSE_FAILED", err) end
            state.visual = nil
        end
        return clean
    end
    local function pageAlive(state)
        if runtime.stopped or state.faulted or state.retired then return false end
        local alive = valid(state.panel) and (state.tab == nil or valid(state.tab.button))
        if alive and state.menu then
            alive = not state.menu.disposed
            if alive and state.menu.valid then alive = state.menu.valid()
            elseif alive then
                for _, entry in ipairs(state.menu.rows) do if not valid(entry.row) then alive = false; break end end
            end
        end
        if alive then return true end
        state.confirming, state.retired = false, true
        runtime.failed[state.address] = true
        retire(state.address, state)
        return false
    end
    tabSelected = function(state)
        if not valid(state.panel) or not valid(state.panel.W_OverlayTabList_C) then return false end
        local ok, selected = pcall(function()
            local function text(id) return type(id) == "string" and id or id:ToString() end
            return text(state.panel.W_OverlayTabList_C:GetSelectedTabId()) == text(state.tab.id)
        end)
        return ok and selected == true
    end
    updatePage = function(state, forceId)
        if not pageAlive(state) then return end
        rebuildPage(state, forceId)
        syncPane(state)
    end
    -- Everything modelsFor reads that can change while the page is open. Building the models took
    -- ~3.5 ms and ran on every 50 ms pass, ~55 ms of every second with the page open (2026-11-05,
    -- measured in game); an unchanged page now skips it. An open editor (key capture, colour edit,
    -- sound preview) always rebuilds.
    local function pageKey(state)
        local editors = state.editors
        if editors and editors.active() then return nil end
        local feedback = editors and editors.feedback() or nil
        local expanded = expandedSections()
        local parts = {currentLocale(), tostring(state.detailsAvailable),
            feedback and (tostring(feedback.id) .. ":" .. tostring(feedback.code)) or "-"}
        for _, record in ipairs(state.records) do
            local snapshot = record.snapshot
            local persistence = snapshot and snapshot.persistence or {}
            local modId = record.provider.modId
            parts[#parts + 1] = table.concat({tostring(modId), tostring(snapshot and snapshot.revision),
                tostring(record.error), tostring(record.errorKind), tostring(record.errorCode), tostring(record.readFailed),
                tostring(persistence.state), tostring(persistence.error), tostring(expanded[modId] == true),
                tostring(inlineConfirm ~= nil and inlineConfirm.armed(modId))}, ",")
        end
        return table.concat(parts, "|")
    end
    local rebuildPageNow
    rebuildPage = function(state, forceId)
        local key = forceId == nil and state.menu ~= nil and not state.menu.disposed and pageKey(state) or nil
        if key and key == state.pageKey then return end
        state.pageKey = nil
        rebuildPageNow(state, forceId)
        -- A nested rebuild (first details pane) has already stored its own, newer key.
        if state.pageKey == nil then state.pageKey = key end
    end
    rebuildPageNow = function(state, forceId)
        local nextModels, byId = modelsFor(state)
        if state.editors and state.editors.reconcile(byId) then nextModels, byId = modelsFor(state) end
        local sameShape = state.models and #state.models == #nextModels
        if sameShape then
            for index, model in ipairs(nextModels) do
                if state.models[index].id ~= model.id or state.models[index].type ~= model.type then sameShape = false; break end
            end
        end
        if not sameShape then
            if state.menu then
                disposePane(state)
                local released = state.menu.dispose()
                if released == false then log("MENU_DISPOSE_FAILED", "incomplete release while rebuilding") end
            end
            state.models, state.byId = nextModels, {}
            for _, model in ipairs(nextModels) do state.byId[model.id] = model end
            state.menu = Menu.create(state.panel, state.tab, nextModels,
                function(model, value, source) changed(state, model, value, source) end, log, menuHandlers(state))
            for index, model in ipairs(nextModels) do
                state.menu.rows[index].row:SetVisibility(model.visible == false and Widgets.V.Collapsed or Widgets.V.SelfHitTestInvisible)
            end
            if state.menu.hasDetails and not state.detailsAvailable then
                -- First page with a details pane: move save/edit state out of the fallback row.
                state.detailsAvailable = true
                return rebuildPage(state, forceId)
            end
            if state.selectedId and state.menu.byId[state.selectedId] then state.menu.select(state.selectedId, "rebuild", false) end
            return
        end
        for index, nextModel in ipairs(nextModels) do
            local model = state.models[index]
            if model.id == forceId or not equalModel(model, nextModel) then
                for key in pairs(model) do model[key] = nil end
                for key, value in pairs(nextModel) do model[key] = value end
                state.menu.update(index, model)
                -- A page forgotten meanwhile (a row found dead) is not touched again.
                if state.menu.disposed then return end
                local entry = state.menu.rows[index]
                local row = entry and entry.row
                if not row then return end
                row:SetVisibility(model.visible == false and Widgets.V.Collapsed or Widgets.V.SelfHitTestInvisible)
            else model.baseRevision = nextModel.baseRevision end
        end
    end

    -- Deferred saves (B09): slider samples only apply; the owner saves on release, when the page is
    -- left or closed, or at the latest DEFER_FLUSH_SECONDS later (the JS store's longest delay).
    local function flushDeferred(state, force)
        for _, record in ipairs(state.records or {}) do
            if record.dirtySince and (force or now() - record.dirtySince >= DEFER_FLUSH_SECONDS) and not record.busy then
                record.dirtySince = nil
                local ok, result = pcall(record.provider.flush)
                if not ok or type(result) ~= "table" or result.ok ~= true then
                    record.error, record.errorKind = tostring(ok and result and result.error or result or "SAVE_FAILED"), "flush"
                    log("PROVIDER_FLUSH_FAILED", record.provider.modId .. " " .. tostring(record.error))
                end
            end
        end
    end

    -- Custom navigation actions (capability navigation = "custom"), JS NativeMenu.move/step/action.
    local function navigationActions(state)
        local function modelOf(id)
            local index = id and state.menu and state.menu.byId[id]
            return index and state.menu.models[index] or nil
        end
        return {
            selected = function() return state.menu and state.menu.selectedId end,
            move = function(id, delta)
                local target = Selection.neighbour(state.models or {}, id, delta)
                if target and state.menu then state.menu.select(target, "key", true) end
            end,
            step = function(id, delta)
                local model = modelOf(id)
                if not model or model.enabled == false then return end
                if model.section then
                    if (model.expanded == true) ~= (delta > 0) then changed(state, model, delta > 0) end
                elseif model.type == "number" then
                    local tick = math.floor((model.value - model.min) / model.step + 0.5) + delta
                    local value = tonumber(string.format("%.10f", math.max(model.min, math.min(model.max, model.min + tick * model.step))))
                    if value ~= model.value then changed(state, model, value, "step") end
                elseif model.options and #model.options > 0 then
                    local index = 1
                    for i, option in ipairs(model.options) do if option.value == model.value then index = i end end
                    changed(state, model, model.options[(index - 1 + delta) % #model.options + 1].value)
                end
            end,
            confirm = function(id)
                local model = modelOf(id)
                if not model or model.enabled == false then return end
                if model.inlineSoundPreview then
                    local copy = {}
                    for key, value in pairs(model) do copy[key] = value end
                    copy.parentId, copy.editorAction, copy.synthetic = model.id, "preview", true
                    changed(state, copy)
                elseif model.type == "action" then changed(state, model)
                else
                    local actions = navigationActions(state)
                    actions.step(id, 1)
                end
            end,
        }
    end

    local function selectHook(state, model, via)
        state.selectedId = model and model.id or nil
        if state.editors and model and via and via ~= "rebuild" then state.editors.select(model.id) end
        -- The details pane and credit are already updated; the preview pane comes after them (both
        -- use the details widget's extension box).
        local paned, paneError = pcall(syncPane, state)
        if not paned then log("PREVIEW_PANE_SYNC_FAILED", paneError) end
        local hook = api.onSelect or options.onSelect
        if type(hook) ~= "function" then return end
        local record = model and model.providerId and state.providers[model.providerId] or nil
        local ok, err = pcall(hook, model, {panel = state.panel, details = state.menu and state.menu.details,
            menu = state.menu, provider = record and record.provider or nil, snapshot = record and record.snapshot or nil,
            editors = state.editors, via = via})
        if not ok and state.lastSelectError ~= tostring(err) then
            state.lastSelectError = tostring(err)
            log("SELECT_HOOK_FAILED", err)
        end
    end

    function menuHandlers(state)
        return {
            preview = function(model)
                if state.editors then
                    local copy = {}
                    for key, value in pairs(model) do copy[key] = value end
                    copy.parentId, copy.editorAction, copy.synthetic = model.id, "preview", true
                    changed(state, copy)
                end
            end,
            commit = function() flushDeferred(state, true) end,
            select = function(model, via) selectHook(state, model, via) end,
            active = function(isActive)
                if not isActive then
                    if inlineConfirm then inlineConfirm.cancel() end
                    if state.editors and state.editors.active() then state.editors.close() end
                    if state.router then state.router.reset() end
                    flushDeferred(state, true)
                end
                pcall(syncPane, state)
            end,
            onCover = function()
                if inlineConfirm then inlineConfirm.cancel() end
                if state.editors and state.editors.active() then state.editors.close() end
                if state.router then state.router.reset() end
                flushDeferred(state, true)
                pcall(syncPane, state)
            end,
            -- The 500 ms poll re-reads every provider; the menu restores focus on resume.
            onResume = function() state.resumed = true end,
            -- Every loop of the menu stands still while a world changes.
            suspended = function() return runtime.suspended == true end,
            allowSelect = function(id)
                local editors = state.editors
                if not editors or not editors.capturing() then return true end
                local active = editors.activeId()
                return id == active or id:sub(1, #active + 2) == active .. "/@"
            end,
            word = word,
            styleChoice = api.styleChoice,
            launch = api.launch,
            now = now,
            capabilities = {authorLink = capabilities.authorLink == true, listStyle = capabilities.listStyle == true,
                coverEvents = capabilities.coverEvents == true, selection = capabilities.selection ~= false},
        }
    end

    local function refreshNow(state)
        if runtime.stopped or runtime.suspended or runtime.panels[state.address] ~= state or state.faulted or state.retired then return end
        if not pageAlive(state) then return end
        refreshRecords(state)
        local refreshed, refreshError = pcall(updatePage, state)
        if not refreshed then faultPage(state, "MENU_UPDATE_FAILED", refreshError) end
    end

    local function queueRefresh(state)
        if state.busy then state.dirty = true; return end
        if state.refreshQueued or runtime.stopped or state.faulted or state.retired then return end
        state.refreshQueued = true
        ExecuteInGameThread(function()
            state.refreshQueued = false
            refreshNow(state)
        end)
    end

    local schemas = setmetatable({}, {__mode = "k"})
    local function schemaOf(provider)
        local schema = schemas[provider]
        if not schema then
            schema = {values = {}, valueList = {}}
            for _, entry in ipairs(provider.entries) do
                if Core.VALUE_TYPES[entry.type] then
                    schema.values[entry.key] = entry
                    schema.valueList[#schema.valueList + 1] = entry
                end
            end
            schemas[provider] = schema
        end
        return schema
    end

    -- Applies one edit, action or reset. Returns {ok, error, fields}. `ok` means the
    -- provider accepted it; a failed save is recorded on the record but is not a rejection.
    local function execute(state, target, value, deferFlush)
        local record = state.providers[target.providerId]
        if not record or record.busy or record.provider ~= target.ownerToken then return {ok = false, error = "STALE_PROVIDER"} end
        record.busy = true
        local provider, stage, applied = record.provider, "apply", nil
        local ok, err = pcall(function()
            local context = {baseRevision = target.baseRevision or target.revision, origin = "PbzModConfig"}
            -- JS Framework.operate: act on a fresh snapshot, not on what the page showed up to 500 ms ago.
            local current = read(provider, record.revision)
            record.snapshot, record.revision = current, current.revision
            if context.baseRevision ~= nil and current.revision ~= context.baseRevision then
                applied = {ok = false, error = "REVISION_CONFLICT"}
                error("REVISION_CONFLICT", 0)
            end
            local function usable(key)
                for _, entry in ipairs(provider.entries) do
                    if entry.key == key then
                        return matches(entry.enabledWhen, current.values) and matches(entry.visibleWhen, current.values)
                    end
                end
                return false
            end
            if target.reset then
                assert(type(provider.reset) == "function", "UNSUPPORTED_RESET")
                applied = provider.reset(nil, context)
            elseif target.type == "action" then
                assert(type(provider.invokeAction) == "function", "UNSUPPORTED_ACTION")
                if not usable(target.key) then
                    applied = {ok = false, error = "DISABLED"}
                    error("DISABLED", 0)
                end
                applied = provider.invokeAction(target.key, context)
            else
                -- target.patch: several values at once (clearing a keyboard binding with its controller companion)
                local patch = target.patch or {[target.key] = value}
                if Core then
                    local problems = Core.validatePatch(schemaOf(provider), patch, current.values)
                    if next(problems) ~= nil then
                        applied = {ok = false, error = "VALIDATION_FAILED", fields = problems}
                        error("VALIDATION_FAILED", 0)
                    end
                end
                for key in pairs(patch) do
                    if not usable(key) then
                        applied = {ok = false, error = "DISABLED"}
                        error("DISABLED", 0)
                    end
                end
                applied = provider.apply(patch, context)
            end
            assert(type(applied) == "table" and applied.ok == true, applied and applied.error or "APPLY_FAILED")
            -- An async provider only accepts delivery; its owner saves on its own schedule.
            if provider.async == true then return end
            if deferFlush then record.dirtySince = record.dirtySince or now(); return end
            stage = "flush"
            local result = provider.flush()
            assert(type(result) == "table" and result.ok == true, result and result.error or "SAVE_FAILED")
            assert(not result.persistence or result.persistence.state ~= "pending", "PERSISTENCE_PENDING")
        end)
        record.busy = false
        if ok then
            record.error, record.errorKind, record.errorCode = nil, nil, nil
            return {ok = true}
        end
        record.error, record.errorKind, record.errorCode = tostring(err), stage, nil
        local fields = type(applied) == "table" and applied.fields or nil
        if type(fields) == "table" then
            for _, code in pairs(fields) do if code == "BINDING_CONFLICT" then record.errorCode = code end end
        end
        log("PROVIDER_" .. stage:upper() .. "_FAILED", provider.modId .. " " .. tostring(err))
        if stage == "flush" then return {ok = true} end
        return {ok = false, error = type(applied) == "table" and applied.error or "PROVIDER_FAILED", fields = fields}
    end

    local function performReset(state, record)
        refreshRecords(state)
        local snapshot = record.snapshot
        if not snapshot or record.readFailed then return end
        if state.editors then state.editors.close() end
        execute(state, {providerId = record.provider.modId, ownerToken = record.provider, baseRevision = snapshot.revision, reset = true})
    end

    -- JS 0.3.13 always asks before resetting. With the native dialog (capability confirmReset) the
    -- answer arrives later; otherwise the reset row arms itself on the first activation and the
    -- second one inside the window resets, so a single accidental activation never resets.
    local function requestReset(state, model)
        local record = state.providers[model.providerId]
        if not record or record.provider ~= model.ownerToken then return end
        if state.editors then state.editors.close() end
        if capabilities.confirmReset == true and type(api.confirmReset) == "function" then
            state.confirming = true
            local settled = false
            local function answer(confirmed)
                if settled then return end
                settled = true
                state.confirming = false
                if runtime.stopped or runtime.panels[state.address] ~= state or not pageAlive(state) then return end
                if confirmed == true then
                    local ok, err = pcall(performReset, state, record)
                    if not ok then log("RESET_FAILED", err) end
                end
                refreshNow(state)
            end
            local ok, shown = pcall(api.confirmReset, state.panel, word("confirm"), answer, state.menu and state.menu.host)
            if not ok or shown == false then
                settled = true
                state.confirming = false
                log("RESET_DIALOG_UNAVAILABLE", ok and "dialog not shown" or shown)
            end
            return
        end
        if not inlineConfirm then
            log("RESET_CONFIRM_UNAVAILABLE", record.provider.modId)
            return
        end
        local verdict = inlineConfirm.request(record.provider.modId)
        if verdict == "confirmed" then performReset(state, record) end
    end

    changed = function(state, model, value, source)
        if runtime.stopped or state.faulted or state.retired
            or (state.byId[model.id] ~= model and not model.synthetic) or not livePanel(state.panel)
            or model.enabled == false or state.confirming then return end
        state.busy = true
        if inlineConfirm and not model.reset then inlineConfirm.cancel() end
        local ok, err = pcall(function()
            local editors = state.editors
            if model.editorChannel ~= nil then
                if editors then editors.edit(model, value) end
            elseif model.editorAction ~= nil then
                if editors then editors.action(model) end
            elseif model.section then
                if editors then editors.close() end
                local sections = expandedSections()
                -- nil = click/confirm toggles; a boolean comes from left/right on the title rotator.
                if type(value) == "boolean" then sections[model.providerId] = value
                else sections[model.providerId] = sections[model.providerId] ~= true end
            elseif model.reset then requestReset(state, model)
            else execute(state, model, value, source == "drag") end
        end)
        state.busy = false
        state.dirty = false
        if not ok then log("EDIT_FAILED", err) end
        refreshRecords(state)
        local refreshed, refreshError = pcall(updatePage, state, model.id)
        if not refreshed then faultPage(state, "MENU_UPDATE_FAILED", refreshError) end
    end

    local function attach(panel)
        local state = {panel = panel, address = panel:GetAddress(), records = {}, providers = {}}
        local ordered = {}
        for _, provider in ipairs(providers) do ordered[#ordered + 1] = provider end
        -- JS orders mods by modId.localeCompare.
        table.sort(ordered, function(a, b)
            local left, right = a.modId:lower(), b.modId:lower()
            if left ~= right then return left < right end
            return a.modId < b.modId
        end)
        for _, provider in ipairs(ordered) do
            local record = {provider = provider}
            state.records[#state.records + 1] = record
            state.providers[provider.modId] = record
        end
        local ok, err = pcall(function()
            local class = StaticFindObject("/Script/GameSettings.GameSettingCollection")
            assert(valid(class), "SETTING_COLLECTION_CLASS_MISSING")
            state.collection = StaticConstructObject(class, panel, 0, 0x40)
            assert(valid(state.collection), "SETTING_COLLECTION_CREATE_FAILED")
            state.tabLabel = resolve(options.tabText or "模组", options)
            local icon
            if capabilities.tabIcon == true and type(api.tabIcon) == "function" then
                local built, texture = pcall(api.tabIcon, panel)
                if built and valid(texture) then icon = texture
                else log("CUSTOM_ICON_FAILED", built and "texture invalid" or texture) end -- the native icon stays
            end
            state.tab = Tabs.attach(panel, state.collection, {id = options.tabId or "PbzModConfig", text = state.tabLabel, icon = icon})
            if keySource and type(keySource.attach) == "function" and (keyCapture == "session" or customNavigation or resetKey) then
                local attached, release = pcall(keySource.attach, panel)
                if attached and type(release) == "function" then state.keyRelease = release
                else log("KEY_SOURCE_ATTACH_FAILED", attached and "no release function" or release) end
            end
            -- The footer's "R 重置本页设置", which the game leaves out on the mod tab.
            if resetKey and ActionBar and type(keySource.demandReset) == "function" then
                state.actionBar = ActionBar.create({report = log})
            end
            if capabilities.tabSpacing == true and type(state.tab.space) == "function" then
                local spaced, spacing = pcall(state.tab.space)
                if spaced then log("TAB_SPACING_APPLIED", spacing.Left .. "," .. spacing.Right) else log("TAB_SPACING_FAILED", spacing) end
            end
            if Editors then
                state.editors = Editors.create({
                    host = {
                        edit = function(ref, value) return execute(state, ref, value) end,
                        preview = function(ref)
                            local record = state.providers[ref.providerId]
                            if not record or record.provider ~= ref.ownerToken then return {ok = false, error = "STALE_PROVIDER"} end
                            local fresh, snapshot = pcall(read, record.provider, record.revision)
                            if not fresh then return {ok = false, error = "STALE_PROVIDER"} end
                            record.snapshot, record.revision = snapshot, snapshot.revision
                            if snapshot.revision ~= ref.revision then return {ok = false, error = "REVISION_CONFLICT"} end
                            local entry
                            for _, candidate in ipairs(record.provider.entries) do if candidate.key == ref.key then entry = candidate end end
                            if not entry or entry.type ~= "sound" or type(record.provider.previewSound) ~= "function" or not playback then
                                return {ok = false, error = "PREVIEW_UNAVAILABLE"}
                            end
                            if not matches(entry.enabledWhen, snapshot.values) or not matches(entry.visibleWhen, snapshot.values) then
                                return {ok = false, error = "DISABLED"}
                            end
                            local focus
                            if capabilities.audioFocus == true and Audio and type(api.audioFocus) == "function" then
                                focus = function()
                                    local built, native = pcall(api.audioFocus, panel)
                                    if not built then log("PREVIEW_AUDIO_FOCUS", "unavailable " .. tostring(native)); return nil end
                                    return Audio.beginFocus(native, log)
                                end
                            end
                            return playback.start({owner = record.provider, key = ref.key, value = snapshot.values[ref.key],
                                beginAudioFocus = focus,
                                play = function() return record.provider.previewSound(ref.key, {baseRevision = snapshot.revision}) end})
                        end,
                        stopPreview = function() if playback then playback.stop() end end,
                    },
                    word = word, refresh = function()
                        queueRefresh(state)
                        -- Evidence for the in-game check: which row captures, and why a key was refused.
                        local editors = state.editors
                        local capturing = editors and editors.capturing() and editors.activeId() or nil
                        if capturing ~= state.captureTraced then
                            state.captureTraced = capturing
                            if capturing then log("KEY_CAPTURE_ROW", capturing .. " selected=" .. tostring(state.menu and state.menu.selectedId)) end
                        end
                        local feedback = editors and editors.feedback()
                        local code = feedback and (tostring(feedback.id) .. " " .. tostring(feedback.code)) or nil
                        if code ~= state.feedbackTraced then
                            state.feedbackTraced = code
                            if code then log("KEY_CAPTURE_FEEDBACK", code) end
                        end
                        -- a polled key source only runs while a capture is open (keySource.demand)
                        if keyCapture == "session" and type(keySource.wake) == "function" then keySource.wake() end
                    end,
                    schedule = schedule, cancel = cancelTimer, compactSound = true, keyCapture = keyCapture,
                })
            end
            refreshRecords(state)
            -- The rows (~70 ms for the map settings in game) are built when the mod tab is first
            -- shown, as the JS list view generated its entries; opening the settings costs only the tab.
            if tabSelected(state) then updatePage(state) end
        end)
        if not ok then
            local closed, released = pcall(close, state)
            if not (closed and released == true) then
                -- native leftovers stay owned by the runtime so a later poll or stop() can retry them
                state.retired = true
                runtime.panels[state.address] = state
            end
            error(err, 0)
        end
        return state
    end

    -- Key events for the JS-style capture session (keyCapture = "session"). An injected
    -- key source calls this for every raw key event while the settings page is open.
    local function routerOf(state)
        if not customNavigation then return nil end
        if not state.router then
            state.router = Selection.router(Navigation.create({now = options.navigationNow}), navigationActions(state))
        end
        return state.router
    end
    -- JS NativeRows: during a capture a left click on a "clear" or "cancel" row still acts on it; any
    -- other mouse button press is the binding. A polled source sees the click before any row does.
    local function clickedEditorRow(state, name, isUp)
        if isUp or name ~= "LeftMouseButton" or keyCapture ~= "session" or type(keySource.wake) ~= "function" then return false end
        local editors, menu = state.editors, state.menu
        if not (editors and editors.capturing()) or type(menu.hoveredModel) ~= "function" then return false end
        local model = menu.hoveredModel()
        if not model or (model.editorAction ~= "cancel" and model.editorAction ~= "clear") then return false end
        changed(state, model)
        return true
    end
    function runtime.feedKey(name, isRepeat, modifiers, isUp)
        if runtime.suspended then return false end
        local handled = false
        for _, state in pairs(runtime.panels) do
            if state.menu and state.menu.active and not state.confirming and not state.menu.covered and pageAlive(state) then
                local editors, router = state.editors, routerOf(state)
                if clickedEditorRow(state, name, isUp) then handled = true
                elseif isUp then
                    if editors and keyCapture == "session" then handled = editors.keyUp(name) or handled end
                    if router then handled = router.keyUp(name) or handled end
                elseif editors and keyCapture == "session" and editors.key(name, isRepeat == true, modifiers) then
                    handled = true
                    if router then router.reset() end
                    queueRefresh(state)
                elseif router then
                    handled = router.key(name, isRepeat == true) or handled
                end
            end
        end
        return handled
    end
    -- Analog axes (Gamepad_LeftX/Y) for the custom navigation; the capture session ignores them.
    function runtime.feedAnalog(name, value)
        if runtime.suspended then return false end
        local handled = false
        for _, state in pairs(runtime.panels) do
            if state.menu and state.menu.active and not state.confirming and not state.menu.covered and pageAlive(state) then
                if state.editors and state.editors.capturing() then handled = true
                else
                    local router = routerOf(state)
                    if router then handled = router.analog(name, value) or handled end
                end
            end
        end
        return handled
    end
    -- Reset key: the selected row's mod, only while the mod tab is active and no dialog is open. A polled
    -- source also reports left clicks, which count only on the footer's reset entry.
    function runtime.feedReset(address, key)
        if runtime.suspended then return false end
        local handled = false
        for _, state in pairs(runtime.panels) do
            local menu = state.menu
            if (address == nil or state.address == address) and pageAlive(state) and menu and not menu.disposed and menu.active
                and not state.confirming and not menu.covered and not state.retired
                and (key ~= "LeftMouseButton" or (state.actionBar ~= nil and state.actionBar.hovered())) then
                local model = menu.selectedModel()
                local row = model and model.providerId and state.byId[model.providerId .. "/@reset"] or nil
                if row and row.enabled ~= false and row.visible ~= false then
                    handled = true
                    changed(state, row)
                end
            end
        end
        return handled
    end
    runtime.unsubscribers = {}
    local function subscribeTo(name, subscribe, listener)
        local ok, unsubscribe = pcall(subscribe, listener)
        if ok and type(unsubscribe) == "function" then
            runtime.unsubscribers[#runtime.unsubscribers + 1] = {name = name, release = unsubscribe}
        else log("KEY_SOURCE_SUBSCRIBE_FAILED", name .. " " .. tostring(unsubscribe)) end
    end
    if keyCapture == "session" or customNavigation then
        subscribeTo("keys", keySource.subscribe, runtime.feedKey)
        if keyCapture == "session" and type(keySource.demand) == "function" then
            -- The panel whose page has a key capture open, or nil.
            keySource.demand(function()
                if runtime.suspended then return nil end
                for _, state in pairs(runtime.panels) do
                    local menu = state.menu
                    if state.editors and state.editors.capturing() and menu and not menu.disposed and menu.active
                        and not menu.covered and not state.confirming and pageAlive(state) then return state.panel end
                end
            end, function(panel)
                -- The capture widget took the focus while it was active: give it back to the selected row.
                for _, state in pairs(runtime.panels) do
                    local menu = state.menu
                    if state.panel == panel and menu and not menu.disposed and menu.active and not menu.covered and menu.selectedId then
                        menu.focus(menu.selectedId)
                    end
                end
            end)
        end
        if customNavigation and type(keySource.subscribeAnalog) == "function" then
            subscribeTo("analog", keySource.subscribeAnalog, runtime.feedAnalog)
        end
    end
    if resetKey then
        subscribeTo("reset", keySource.subscribeReset, runtime.feedReset)
        if type(keySource.demandReset) == "function" then
            -- A polled source watches R / controller X only while the mod page could act on them.
            keySource.demandReset(function()
                if runtime.suspended then return nil end
                for _, state in pairs(runtime.panels) do
                    local menu = state.menu
                    if menu and not menu.disposed and menu.active and not menu.covered and not state.confirming
                        and not (state.editors and state.editors.active()) and pageAlive(state) then return state.panel end
                end
            end)
        end
    end

    local function syncTabLabel(state)
        if not state.tab or type(state.tab.setLabel) ~= "function" then return end
        local label = resolve(options.tabText or "模组", options)
        if label == state.tabLabel then return end
        local ok, err, arrayUpdated = pcall(state.tab.setLabel, label)
        state.tabLabel = label -- one attempt per language change; a failure is logged, never retried every poll
        if ok then log("TAB_LABEL_UPDATED", label .. (arrayUpdated == false and " (descriptor array not updated)" or ""))
        else log("TAB_LABEL_FAILED", err) end
    end

    -- Releases every panel on the calling (game) thread. True once nothing is left; on false the
    -- unreleased panels stay in runtime.panels and a later stop() retries them.
    -- JS: reloading is refused while a dialog or sub-page covers the page (MOD_CONFIG_DIALOG_ACTIVE).
    function runtime.busy()
        for _, state in pairs(runtime.panels) do
            if state.confirming or (state.menu and not state.menu.disposed and state.menu.covered) then return true end
        end
        return false
    end

    function runtime.stop(force)
        if runtime.closed then return true end
        if force ~= true and runtime.busy() then
            log("MOD_CONFIG_DIALOG_ACTIVE", "stop refused while a dialog is open")
            return false
        end
        -- A page that is showing hands the panel back to the first native tab before anything is released
        -- (JS loader.stop); if the tab list refuses, the runtime stays fully alive.
        for _, state in pairs(runtime.panels) do
            if state.menu and state.tab and state.menu.active and not state.menu.disposed and not state.returnedToNative then
                local returned, reason = returnToNativeTab(state)
                if not returned then
                    log("NATIVE_TAB_RETURN_REQUIRED", reason)
                    return false
                end
                state.returnedToNative = true
            end
        end
        runtime.stopped = true
        local clean = true
        for index = #runtime.unsubscribers, 1, -1 do
            local item = runtime.unsubscribers[index]
            local ok, released = pcall(item.release)
            if ok and released ~= false then table.remove(runtime.unsubscribers, index)
            else
                clean = false
                log("KEY_SOURCE_RELEASE_FAILED", item.name .. " " .. tostring(ok and "incomplete release" or released))
            end
        end
        if playback then
            local ok, err = pcall(playback.stop)
            if not ok then log("PREVIEW_STOP_FAILED", err) end
        end
        -- The same path as any other retirement: a panel found gone is forgotten, not closed.
        for address, state in pairs(runtime.panels) do
            local ok, released = pcall(retire, address, state)
            if not (ok and released == true) then
                clean = false
                state.retired = true
                if not ok then log("PANEL_DISPOSE_FAILED", released) end
            end
        end
        if not clean then return false end
        runtime.closed = true
        if runtime.worldRouter and runtime.worldRouter.listener == onWorld then runtime.worldRouter.listener = nil end
        if rawget(_G, SLOT) == runtime then rawset(_G, SLOT, nil) end
        return true
    end

    -- A panel that is gone, replaced or failed: release it; if that is incomplete it stays queued.
    -- A panel that did not survive a world change is forgotten in Lua only: closing it would select
    -- tabs, remove widgets and unbind delegates of objects that died with the old world (review 2026-11-05).
    local function forget(address, state)
        if state.menu and type(state.menu.abandon) == "function" then pcall(state.menu.abandon) end
        if state.editors and type(state.editors.discardWorld) == "function" then pcall(state.editors.discardWorld) end
        if state.actionBar then pcall(state.actionBar.dispose) end
        state.retired, state.faulted, state.keyRelease = true, true, nil
        state.menu, state.tab = nil, nil
        runtime.panels[address] = nil
        log("PANEL_FORGOTTEN", tostring(address))
        return true
    end
    runtime.forget = forget

    -- World changes (UE4SS LoadMap hooks, registered once per Lua state). LoadMapPre suspends every
    -- engine call of the page - the poll, the menu loops, the key watches - and drops in Lua what belongs
    -- to the old world; the poll resumes RESUME_SECONDS after LoadMapPost and then forgets the panels that
    -- did not survive. A panel kept by the game instance across the load stays in use.
    local function pauseEvents(paused)
        if Events and type(Events.pause) == "function" then pcall(Events.pause, paused) end
    end
    runtime.suspended, runtime.resumeAt = true, now() + Runtime.START_WAIT_SECONDS
    pauseEvents(true)
    local function onWorld(reason)
        if runtime.stopped then return end
        if reason == "load-map-pre" then
            runtime.suspended, runtime.resumeAt = true, nil
            pauseEvents(true)
            runtime.worldChanges = (runtime.worldChanges or 0) + 1
            if keySource and type(keySource.discardWorld) == "function" then pcall(keySource.discardWorld) end
            if Confirm and type(Confirm.discardWorld) == "function" then pcall(Confirm.discardWorld) end
            -- Every page belongs to the world being torn down: forgotten in Lua now (routes revoked,
            -- nothing native touched); pages are built again from the panels found after the load.
            runtime.forgottenByLoad = {}
            for address, state in pairs(runtime.panels) do
                forget(address, state)
                runtime.forgottenByLoad[address] = true
            end
        elseif reason == "load-map-post" and runtime.suspended then
            runtime.resumeAt = now() + Runtime.RESUME_SECONDS
        end
    end
    do
        local router = rawget(_G, WORLD_SLOT)
        if type(router) ~= "table" then router = {registered = {}}; rawset(_G, WORLD_SLOT, router) end
        router.listener = onWorld
        runtime.worldRouter = router
        for name, reason in pairs({RegisterLoadMapPreHook = "load-map-pre", RegisterLoadMapPostHook = "load-map-post"}) do
            local register = options.globals and options.globals[name] or rawget(_G, name)
            if not router.registered[name] and type(register) == "function" then
                local ok, err = pcall(register, function()
                    local listener = router.listener
                    if listener then pcall(listener, reason) end
                    -- never return a value: LoadMap hooks may override native results
                end)
                if ok then router.registered[name] = true else log("WORLD_HOOK_FAILED", name .. " " .. tostring(err)) end
            end
        end
    end
    runtime.onWorld = onWorld

    retire = function(address, state)
        if runtime.suspended or not valid(state.panel) then return forget(address, state) end
        local ok, released = pcall(close, state)
        if ok and released == true then
            runtime.panels[address] = nil
            return true
        end
        state.retired = true
        log("PANEL_DISPOSE_FAILED", ok and "incomplete release" or released)
        return false
    end

    local function poll()
        if runtime.stopped then return end
        ExecuteInGameThread(function()
            if runtime.stopped then return end
            if runtime.suspended then
                if not (runtime.resumeAt and now() >= runtime.resumeAt) then
                    ExecuteInGameThreadWithDelay(Runtime.POLL_MS, poll)
                    return
                end
                runtime.suspended, runtime.resumeAt = false, nil
                pauseEvents(false)
            end
            runtime.panelSeen = false
            runtime.panelCount = 0
            local passStart = os.clock()
            local ok, err = pcall(function()
                if previous and not previous.closed then return end
                local live = {}
                for _, panel in ipairs(FindAllOf("W_PBZSettingPanel_C") or {}) do
                    runtime.panelCount = (runtime.panelCount or 0) + 1
                    if livePanel(panel) then live[panel:GetAddress()] = panel; runtime.panelSeen = true end
                end
                for address, state in pairs(runtime.panels) do
                    if state.retired or state.faulted or not live[address] then retire(address, state) end
                end
                for address in pairs(runtime.failed) do if not live[address] then runtime.failed[address] = nil end end
                for address, panel in pairs(live) do
                    local state = runtime.panels[address]
                    if state then
                        if not state.retired and not state.faulted then
                            local tabList = panel.W_OverlayTabList_C
                            local button = valid(tabList) and tabList:GetTabButtonBaseByID(state.tab.id) or nil
                            if (state.menu and state.menu.disposed) or not valid(button) or not valid(state.tab.button)
                                or button:GetAddress() ~= state.tab.button:GetAddress() then
                                runtime.failed[address] = true
                                retire(address, state)
                            else
                                -- Leaving the mod tab revokes any unfinished edit or preview.
                                if state.editors and not (state.menu and state.menu.active) and state.editors.active() then state.editors.close() end
                                local updated, failure = pcall(function()
                                    syncTabLabel(state)
                                    flushDeferred(state, false)
                                    refreshRecords(state)
                                    if state.menu or tabSelected(state) then updatePage(state) end
                                    local menu = state.menu
                                    if state.actionBar and menu and not menu.disposed and menu.active and not menu.covered then
                                        state.actionBar.sync(panel)
                                    end
                                end)
                                if not updated then faultPage(state, "MENU_UPDATE_FAILED", failure) end
                            end
                        end
                    elseif not runtime.failed[address] and readyPanel(panel) then
                        local attachStart = os.clock()
                        local attached, result = pcall(attach, panel)
                        -- Measurement hook for test builds: a job sets __PBZ_MODCONFIG_PERF__ = {} to collect
                        -- page build time and how many settings panels the search finds (growth = leftovers).
                        local perf = rawget(_G, "__PBZ_MODCONFIG_PERF__")
                        if type(perf) == "table" and #perf < 200 then
                            perf[#perf + 1] = string.format("attach=%.1fms pass=%.1fms panels=%d at=%.3f",
                                (os.clock() - attachStart) * 1000, runtime.lastPassMs or -1, runtime.panelCount or 0, attachStart)
                        end
                        if attached then runtime.panels[address] = result
                        else
                            runtime.failed[address] = true
                            log("PANEL_ATTACH_FAILED", result)
                            -- A panel kept by the game across a load still carries the tab of a forgotten
                            -- page; it stays without the mod page until the game builds a new panel.
                            if runtime.forgottenByLoad and runtime.forgottenByLoad[address]
                                and tostring(result):find("MOD_TAB_ALREADY_OWNED", 1, true) then
                                log("PANEL_KEPT_ACROSS_LOAD", address)
                            end
                        end
                    end
                end
                if resetKey and type(keySource.wakeReset) == "function" then
                    local woke, failure = pcall(keySource.wakeReset)
                    if not woke then log("KEY_SOURCE_WAKE_FAILED", failure) end
                end
                -- A reload deferred by the bridge while a dialog was open can go ahead now.
                local busy = runtime.busy()
                if runtime.wasBusy and not busy and type(options.onIdle) == "function" then
                    local notified, failure = pcall(options.onIdle)
                    if not notified then log("IDLE_HANDLER_FAILED", failure) end
                end
                runtime.wasBusy = busy
            end)
            if not ok then
                if runtime.lastPollError ~= tostring(err) then log("RUNTIME_POLL_FAILED", err) end
                runtime.lastPollError = tostring(err)
            else runtime.lastPollError = nil end
            runtime.lastPassMs = (os.clock() - passStart) * 1000
            runtime.maxPassMs = math.max(runtime.maxPassMs or 0, runtime.lastPassMs)
            -- While a settings panel exists the tab must appear promptly: a 500 ms period left it up
            -- to half a second late (session 1, measured 84-451 ms). The pass only reads, so it runs
            -- every 50 ms then; with no panel it stays at 500 ms.
            if not runtime.stopped then
                ExecuteInGameThreadWithDelay(runtime.panelSeen and Runtime.FAST_POLL_MS or Runtime.POLL_MS, poll)
            end
        end)
    end
    poll()
    return runtime
end

return Runtime
