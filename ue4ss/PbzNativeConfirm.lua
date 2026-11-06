-- "Reset to defaults" confirmation. JS 0.3.13 always asks with the game's own yes/no dialog
-- (AsyncAction_ShowConfirmation.ShowConfirmationYesNo) and never resets without a Confirmed result.
--
-- Confirm.native(deps) builds that dialog for UE4SS (unconfirmed in game: capability confirmReset).
-- Confirm.inline(deps) is the always-safe fallback when the dialog is off or unavailable: the first
-- activation only arms the row (its button asks to confirm), a second activation within the window
-- resets. A single accidental click never resets in either mode.
local Confirm = {}

local function valid(object) return object ~= nil and object:IsValid() end

function Confirm.inline(deps)
    deps = deps or {}
    local window = deps.windowSeconds or 4
    local now = deps.now or os.clock
    local armedKey, armedAt
    local self = {}
    -- Returns "armed" for the first activation and "confirmed" for a second one in time.
    function self.request(key)
        local t = now()
        if armedKey == key and armedAt and t - armedAt <= window then
            armedKey, armedAt = nil, nil
            return "confirmed"
        end
        armedKey, armedAt = key, t
        return "armed"
    end
    function self.armed(key)
        if armedKey ~= key or not armedAt then return false end
        if now() - armedAt > window then armedKey, armedAt = nil, nil; return false end
        return true
    end
    function self.cancel() armedKey, armedAt = nil, nil end
    return self
end

local PACKAGES = {"/Script/CommonGame.", "/Script/ProjectPBZ.", "/Script/CommonUI."}
-- A rarely used native function whose only parameter is a uint8 enum: it receives the dialog's
-- ECommonMessagingResult on a hidden dummy ScrollBox (same routing idea as PbzNativeEvents).
local RECEIVER_CLASS, RECEIVER_FUNCTION = "/Script/UMG.ScrollBox", "SetScrollBarVisibility"

-- deps: find(path), construct(class, outer), text(string)->FText, registerHook(path, fn)->pre,post,
--       schedule(ms, fn), defer(fn), timeoutMs, report(code, detail)
--
-- One hook on the receiver function per Lua state, registered on first use and never removed; requests
-- add and remove routes keyed by receiver address. The answer and every native clean-up run on a later
-- game-thread step, never inside the dialog's own broadcast (review 2026-11-05: removing the hook,
-- the binding and the receiver while OnResult was still being broadcast).
local HUB = "__PBZ_MODCONFIG_CONFIRM_HOOK_V1__"
-- World generation shared by every dialog of this Lua state: a world change ends the open requests
-- without touching their receiver or action, which die with the old world (review 2026-11-05).
local generation = 0
function Confirm.discardWorld() generation = generation + 1; return true end

function Confirm.native(deps)
    deps = deps or {}
    local find = deps.find or StaticFindObject
    local construct = deps.construct or function(class, outer) return StaticConstructObject(class, outer, 0, 0x40) end
    local registerHook = deps.registerHook or RegisterHook
    local schedule = deps.schedule or ExecuteInGameThreadWithDelay
    local defer = deps.defer or ExecuteInGameThread
    local timeoutMs = deps.timeoutMs or 120000
    local report = deps.report or function() end
    local text = deps.text or function(value)
        local library = find("/Script/Engine.Default__KismetTextLibrary")
        assert(valid(library), "TEXT_LIBRARY_MISSING")
        return library:Conv_StringToText(value)
    end
    local function lookup(name)
        for _, package in ipairs(PACKAGES) do
            local object = find(package .. name)
            if valid(object) then return object, package end
        end
    end
    local function confirmedValue()
        local enum = lookup("ECommonMessagingResult")
        local value = 0 -- declaration order: Confirmed, Declined, Cancelled, Killed, Unknown
        if enum then
            pcall(function()
                enum:ForEachName(function(name, number)
                    local label = type(name) == "userdata" and name:ToString() or tostring(name)
                    if label == "Confirmed" or label:match("::Confirmed$") then value = number end
                end)
            end)
        end
        return value
    end

    local path = RECEIVER_CLASS .. ":" .. RECEIVER_FUNCTION
    local function listen()
        local shared = rawget(_G, HUB)
        if not shared then shared = {routes = {}}; rawset(_G, HUB, shared) end
        if not shared.hooked then
            registerHook(path, function(context, value)
                local found, target = pcall(function() return context:get() end)
                if not found or not valid(target) then return end
                local route = shared.routes[target:GetAddress()]
                if route then route(value and value:get()) end
            end)
            shared.hooked = true
        end
        return shared.routes
    end

    -- Returns true when the dialog is showing; answer(confirmed) is called exactly once later.
    -- `host` must be a panel widget owned by the menu: it keeps the receiver alive (an unparented
    -- UObject could be garbage collected while the dialog is open and the answer would never arrive).
    return function(panel, message, answer, host)
        assert(type(answer) == "function", "CONFIRM_ANSWER_REQUIRED")
        if not valid(panel) or not valid(host) or not valid(panel.WidgetTree) then return false end
        local library = lookup("Default__AsyncAction_ShowConfirmation")
        if not library then return false end
        local receiverClass = find(RECEIVER_CLASS)
        if not valid(receiverClass) then return false end
        local settled, receiver, action, pending = false, nil, nil, nil
        local routes, address, route = nil, nil, nil
        local born = generation
        local function cleanup()
            if routes and address and routes[address] == route then routes[address] = nil end
            if born ~= generation then receiver, action = nil, nil; return end
            if valid(action) and valid(receiver) then pcall(function() action.OnResult:Remove(receiver, RECEIVER_FUNCTION) end) end
            if valid(receiver) then pcall(function() receiver:RemoveFromParent() end) end
            receiver, action = nil, nil
        end
        local function finish(confirmed, why)
            cleanup()
            if born ~= generation then return end -- the page that asked belongs to an earlier world
            if why then report(why, "") end
            local ok, err = pcall(answer, confirmed == true)
            if not ok then report("RESET_ANSWER_FAILED", err) end
        end
        local function settle(confirmed, why)
            if settled then return end
            settled = true
            finish(confirmed, why)
        end
        local confirmed = confirmedValue()
        -- The timeout is armed before anything is shown: a dialog that never answers must not block
        -- the menu for good, so without a timer there is no dialog (review 2026-11-05, round 4).
        local armed = pcall(schedule, timeoutMs, function()
            if pending ~= nil then local answered = pending; pending = nil; finish(answered); return end
            settle(false, "RESET_DIALOG_TIMEOUT")
        end)
        if not armed then
            settled = true
            report("RESET_DIALOG_UNAVAILABLE", "no timer")
            return false
        end
        local ok, err = pcall(function()
            -- Outered directly to the transient package: OnResult:Add makes the receiver's first weak
            -- reference, and this UE4SS build copies a widget-tree sub-path with a wrong element size
            -- (three crashes; see PbzNativeEvents). The host keeps the receiver alive.
            local transient = find("/Engine/Transient")
            assert(valid(transient), "CONFIRM_TRANSIENT_PACKAGE_MISSING")
            receiver = construct(receiverClass, transient)
            assert(valid(receiver), "CONFIRM_RECEIVER_FAILED")
            receiver:SetVisibility(1)
            host:AddChild(receiver)
            address = receiver:GetAddress()
            routes = listen()
            route = function(result)
                if settled or born ~= generation then return end
                settled = true
                -- Only Lua here: the clean-up and the answer wait for the broadcast to end.
                local deferred = pcall(defer, function() finish(result == confirmed) end)
                -- Never clean up inside the broadcast: without a deferral the timeout delivers the answer.
                if not deferred then pending = result == confirmed; report("RESET_DIALOG_DEFER_FAILED", "") end
            end
            routes[address] = route
            action = library:ShowConfirmationYesNo(panel, text(""), text(message))
            assert(valid(action), "RESET_DIALOG_UNAVAILABLE")
            action.OnResult:Add(receiver, RECEIVER_FUNCTION)
            action:Activate()
        end)
        if not ok then
            settled = true
            cleanup()
            report("RESET_DIALOG_UNAVAILABLE", err)
            return false
        end
        return true
    end
end

return Confirm
