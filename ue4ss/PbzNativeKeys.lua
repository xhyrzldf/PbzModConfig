-- Key source of the mod settings page (api.keySource): polling, the one route that works in game.
--
-- JS 0.3.13 saw every key because its rows were list entries whose preview-key handlers it owned, and it
-- replaced the panel's handleResetKeyPressed for the mod tab. Lua owns neither. The earlier candidates were
-- removed in the review of 2026-11-05: RegisterHook on UMG/CommonUI key events saw no event at all in game
-- (p63), hooking functions by name on the panel's Blueprint chain reaches functions the game's script
-- (PuerTS) takes over - the pattern that crashed the game the same day - and RegisterKeyBind could not
-- capture arbitrary keys.
--
-- Poll: only while the page asks for it (demand), every frame the UI action router's IsUIKeyHeld for each
-- bindable key (keyboard, mouse buttons, gamepad: all seen in game, 2026-11-05), with the game's own capture
-- widget W_KeyCapture_Invisible (PBZSettingPressAnyKey, what the native key binding rows use) held active
-- so the keys do not also move, confirm or close the menu. No repeats, no analog axes; ~0.5 ms a frame,
-- only during a capture. The native reset key (R, controller X) and a click on the footer's reset entry
-- are watched the same way while the mod page takes them (demandReset).
--
-- keySource = {name="poll", anyKey=true, consumes=false,
--   subscribe(fn(name, isRepeat, modifiers, isUp)) -> unsubscribe,
--   demand(fn() -> live panel|nil, released(panel)), wake(),
--   subscribeReset(fn(panelAddress, keyName)) -> unsubscribe, demandReset(fn), wakeReset()   (resetKey on)
--   discardWorld() -> true, dispose() -> true}
local Keys = {}

-- Every key a capture session can bind (EKeys names). Mouse wheel and analog axes are not bindable
-- (PROTOCOL.md); the stick directions are buttons in UE, as they were key events for JS.
Keys.POLL_KEYS = {}
do
    local list = Keys.POLL_KEYS
    for c = string.byte("A"), string.byte("Z") do list[#list + 1] = string.char(c) end
    for _, name in ipairs({"Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"}) do list[#list + 1] = name end
    for i = 1, 12 do list[#list + 1] = "F" .. i end
    for _, name in ipairs({"Escape", "Tab", "CapsLock", "SpaceBar", "Enter", "BackSpace", "Insert", "Delete", "Home", "End",
        "PageUp", "PageDown", "Up", "Down", "Left", "Right", "Pause", "ScrollLock", "NumLock",
        "Tilde", "Hyphen", "Equals", "LeftBracket", "RightBracket", "Backslash", "Semicolon", "Apostrophe", "Comma",
        "Period", "Slash", "NumPadZero", "NumPadOne", "NumPadTwo", "NumPadThree", "NumPadFour", "NumPadFive", "NumPadSix",
        "NumPadSeven", "NumPadEight", "NumPadNine", "Multiply", "Add", "Subtract", "Decimal", "Divide",
        "LeftShift", "RightShift", "LeftControl", "RightControl", "LeftAlt", "RightAlt",
        "LeftMouseButton", "RightMouseButton", "MiddleMouseButton", "ThumbMouseButton", "ThumbMouseButton2",
        "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right", "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Top",
        "Gamepad_LeftShoulder", "Gamepad_RightShoulder", "Gamepad_LeftTrigger", "Gamepad_RightTrigger",
        "Gamepad_DPad_Up", "Gamepad_DPad_Down", "Gamepad_DPad_Left", "Gamepad_DPad_Right",
        "Gamepad_LeftThumbstick", "Gamepad_RightThumbstick", "Gamepad_Special_Left", "Gamepad_Special_Right",
        "Gamepad_LeftStick_Up", "Gamepad_LeftStick_Down", "Gamepad_LeftStick_Left", "Gamepad_LeftStick_Right",
        "Gamepad_RightStick_Up", "Gamepad_RightStick_Down", "Gamepad_RightStick_Left", "Gamepad_RightStick_Right"}) do
        list[#list + 1] = name
    end
end
Keys.CAPTURE_WIDGET = "/Game/PBZContent/UI/GameSystem/Settings/W_KeyCapture_Invisible.W_KeyCapture_Invisible_C"
-- The native "reset this page" key (footer of the game's own tabs: R, controller X). The game's script
-- handles it on its own tabs (JS wrapped handleResetKeyPressed, out of Lua's reach); the poll source
-- watches these keys while the mod page takes them (demandReset). A left click is passed on too: the
-- page decides whether it was on the footer's reset entry.
Keys.RESET_KEYS = {"R", "Gamepad_FaceButton_Left", "LeftMouseButton"}
Keys.DRAIN_SECONDS = 1

local MODIFIER_KEYS = {LeftControl = true, RightControl = true, LeftAlt = true, RightAlt = true,
    LeftShift = true, RightShift = true, LeftCommand = true, RightCommand = true}

local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
end


-- options: resetKey (any true value), find, frames(n, fn), now, report, fname(text), router(owner) and
-- captureWidget(owner) (tests).
function Keys.create(options)
    options = options or {}
    local find = options.find or StaticFindObject
    local now = options.now or os.clock
    local function report(code, detail)
        if options.report then pcall(options.report, code, tostring(detail or "")) end
    end
    local resetPolled = options.resetKey ~= nil and options.resetKey ~= false
    local press, reset = {}, {}
    local disposed = false
    local lastPanel = nil
    local self = {name = "poll", anyKey = true, consumes = false}

    local function each(list, ...)
        for _, listener in ipairs({table.unpack(list)}) do
            local ok, err = xpcall(listener, debug.traceback, ...)
            if not ok then report("KEY_SOURCE_CALLBACK_FAILED", err) end
        end
    end
    local frames = options.frames or rawget(_G, "ExecuteInGameThreadAfterFrames")
    local demandOf, releasedOf, poll, keyNames = nil, nil, nil, nil
    -- Evidence for the in-game check, bounded so a long session cannot flood the log.
    local traced = 0
    local function trace(code, detail)
        traced = traced + 1
        if traced <= 60 then report(code, detail) end
    end

    local function wanted()
        if disposed or #press == 0 or not demandOf then return nil end
        local ok, owner = pcall(demandOf)
        if ok and valid(owner) then return owner end
        if not ok then report("KEY_POLL_DEMAND_FAILED", owner) end
        return nil
    end

    local function routerOf(owner)
        if options.router then return options.router(owner) end
        local library = find("/Script/Engine.Default__SubsystemBlueprintLibrary")
        local class = find("/Script/ProjectPBZ.PBZUIActionRouterBase")
        assert(valid(library) and valid(class), "KEY_POLL_UNAVAILABLE")
        local router = library:GetLocalPlayerSubsystem(owner, class)
        assert(valid(router), "KEY_POLL_UNAVAILABLE")
        return router
    end

    local function sample(p)
        if not keyNames then
            local make = options.fname or function(name) return FName(name, EFindName.FNAME_Add) end
            keyNames = {}
            for index, name in ipairs(Keys.POLL_KEYS) do keyNames[index] = make(name) end
        end
        local held, router = {}, p.router
        for index, name in ipairs(Keys.POLL_KEYS) do
            if router:IsUIKeyHeld({KeyName = keyNames[index]}) == true then held[name] = true end
        end
        return held
    end

    -- The game's capture widget swallows input while activated and dismisses itself after each key; it is
    -- activated again every frame of the capture. Without it the capture still works, unshielded.
    local function nativeWidget(owner)
        local class = find(Keys.CAPTURE_WIDGET)
        if not valid(class) and type(rawget(_G, "LoadAsset")) == "function" then
            pcall(LoadAsset, Keys.CAPTURE_WIDGET:match("^(.-)%."))
            class = find(Keys.CAPTURE_WIDGET)
        end
        assert(valid(class), "KEY_CAPTURE_WIDGET_MISSING")
        local player = owner:GetOwningPlayer()
        local library = find("/Script/UMG.Default__WidgetBlueprintLibrary")
        assert(valid(player) and valid(library), "KEY_CAPTURE_WIDGET_OWNER_MISSING")
        local widget = library:Create(player, class, player)
        assert(valid(widget), "KEY_CAPTURE_WIDGET_CREATE_FAILED")
        widget:AddToViewport(1000)
        return widget
    end
    local function shield(p)
        if p.widget == false then return end
        if p.widget == nil then
            local ok, widget = pcall(options.captureWidget or nativeWidget, p.owner)
            if not ok then p.widget = false; report("KEY_CAPTURE_SHIELD_UNAVAILABLE", widget); return end
            p.widget = widget
        end
        -- The game may remove the widget at any frame: checked before each use (review 2026-11-05).
        if not valid(p.widget) then
            p.widget = false
            report("KEY_CAPTURE_SHIELD_LOST", "the capture continues unshielded")
            return
        end
        if p.widget:IsActivated() ~= true then
            p.widget:ActivateWidget()
            p.activations = (p.activations or 0) + 1
        end
    end
    local function unshield(p)
        local widget = p.widget
        p.widget = nil
        if widget then
            local ok, err = pcall(function()
                if valid(widget) then widget:DeactivateWidget(); widget:RemoveFromParent() end
            end)
            if not ok then report("KEY_CAPTURE_SHIELD_RELEASE_FAILED", err) end
        end
    end

    local function finish(p)
        if poll == p then poll = nil end
        trace("KEY_CAPTURE_ENDED", "shield=" .. tostring(p.widget ~= false) .. " activations=" .. tostring(p.activations or 0))
        unshield(p)
        if releasedOf then
            local ok, err = pcall(releasedOf, p.owner)
            if not ok then report("KEY_POLL_RELEASE_FAILED", err) end
        end
    end

    local function pollFrame()
        local p = poll
        if not p then return end
        -- The page or its router is gone (a world change): drop the capture, touch nothing of it. The
        -- owner is compared before the cached router is sampled (review 2026-11-05).
        if not valid(p.owner) or not valid(p.router) then poll = nil; return end
        local owner = wanted()
        local ok, err = pcall(function()
            if owner == p.owner then
                local held = sample(p)
                if p.draining then
                    -- a new capture began before the last one was released: held keys start it again
                    p.draining, p.ignore = nil, {}
                    for name in pairs(held) do p.ignore[name] = true end
                end
                shield(p)
                local modifiers = {Ctrl = held.LeftControl or held.RightControl or false, Alt = held.LeftAlt or held.RightAlt or false,
                    Shift = held.LeftShift or held.RightShift or false, Cmd = false}
                local before = p.held
                p.held = held
                for _, name in ipairs(Keys.POLL_KEYS) do
                    local down, was = held[name] == true, before[name] == true
                    if down and not was then
                        trace("KEY_CAPTURE_KEY", name .. (p.ignore[name] and " (held before)" or ""))
                        if not p.ignore[name] then each(press, name, false, MODIFIER_KEYS[name] and {} or modifiers, false) end
                    elseif was and not down then
                        if p.ignore[name] then p.ignore[name] = nil else each(press, name, false, {}, true) end
                    end
                    if poll ~= p then break end
                end
                return
            end
            -- The capture ended (or moved to another panel): stay shielded until every key is up, or the
            -- key that ended it would reach the menu on its release.
            p.draining = p.draining or now()
            if owner ~= nil then finish(p); return end
            local held = sample(p)
            if next(held) == nil or now() - p.draining > Keys.DRAIN_SECONDS then finish(p) end
        end)
        if not ok then
            report("KEY_POLL_FAILED", err)
            finish(p)
        end
        if poll == p then
            frames(1, pollFrame)
        elseif poll == nil and owner ~= nil and ok then
            self.wake()
        end
    end

    local function pollWake()
        if poll or type(frames) ~= "function" then return poll ~= nil end
        local owner = wanted()
        if not owner then return false end
        local ok, err = pcall(function()
            local p = {owner = owner, router = routerOf(owner)}
            p.held = sample(p)
            -- Keys already down (the Enter, A or click that started the capture) count once released.
            p.ignore = {}
            for name in pairs(p.held) do p.ignore[name] = true end
            poll = p
            shield(p)
            local held = {}
            for name in pairs(p.ignore) do held[#held + 1] = name end
            table.sort(held)
            trace("KEY_CAPTURE_STARTED", "held=" .. table.concat(held, "+") .. " shield=" .. tostring(p.widget ~= false))
        end)
        if not ok then
            report("KEY_POLL_FAILED", err)
            if poll then finish(poll) end
            return false
        end
        frames(1, pollFrame)
        return true
    end

    -- Reset keys: a fresh press of one of them while demandReset() names a panel; keys already down when
    -- the watch starts count once released.
    local resetDemandOf, watch = nil, nil
    local function resetWanted()
        if disposed or #reset == 0 or not resetDemandOf then return nil end
        local ok, owner = pcall(resetDemandOf)
        if ok and valid(owner) then return owner end
        if not ok then report("KEY_POLL_DEMAND_FAILED", owner) end
        return nil
    end
    local resetNamesOf
    local function resetHeld(w)
        if not resetNamesOf then
            local make = options.fname or function(name) return FName(name, EFindName.FNAME_Add) end
            resetNamesOf = {}
            for index, name in ipairs(Keys.RESET_KEYS) do resetNamesOf[index] = make(name) end
        end
        local held = {}
        for index, name in ipairs(Keys.RESET_KEYS) do
            if w.router:IsUIKeyHeld({KeyName = resetNamesOf[index]}) == true then held[name] = true end
        end
        return held
    end
    local function watchFrame()
        local w = watch
        if not w then return end
        if not valid(w.owner) or not valid(w.router) then watch = nil; return end
        local owner = resetWanted()
        if owner ~= w.owner then
            watch = nil
            if owner then self.wakeReset() end
            return
        end
        local ok, err = pcall(function()
            local held = resetHeld(w)
            for _, name in ipairs(Keys.RESET_KEYS) do
                if held[name] and not w.held[name] then
                    local address = try(function() return owner:GetAddress() end)
                    each(reset, address, name)
                end
            end
            w.held = held
        end)
        if not ok then
            report("KEY_POLL_FAILED", err)
            watch = nil
            return
        end
        if watch == w then frames(1, watchFrame) end
    end
    local function wakeReset()
        if watch or type(frames) ~= "function" then return watch ~= nil end
        local owner = resetWanted()
        if not owner then return false end
        local ok, err = pcall(function()
            local w = {owner = owner, router = routerOf(owner)}
            w.held = resetHeld(w)
            watch = w
        end)
        if not ok then report("KEY_POLL_FAILED", err); return false end
        frames(1, watchFrame)
        return true
    end

    self.subscribe = function(listener)
        assert(type(listener) == "function", "KEY_LISTENER_REQUIRED")
        assert(not disposed, "KEY_SOURCE_DISPOSED")
        press[#press + 1] = listener
        return function()
            for index, candidate in ipairs(press) do
                if candidate == listener then table.remove(press, index); break end
            end
            return true
        end
    end
    function self.demand(fn, released)
        assert(type(fn) == "function", "KEY_DEMAND_REQUIRED")
        demandOf, releasedOf = fn, released
    end
    self.wake = pollWake
    self.anyKey = true
    if resetPolled then
        self.subscribeReset = function(listener)
            assert(type(listener) == "function", "KEY_LISTENER_REQUIRED")
            assert(not disposed, "KEY_SOURCE_DISPOSED")
            reset[#reset + 1] = listener
            return function()
                for index, candidate in ipairs(reset) do
                    if candidate == listener then table.remove(reset, index); break end
                end
                return true
            end
        end
        function self.demandReset(fn)
            assert(type(fn) == "function", "KEY_DEMAND_REQUIRED")
            resetDemandOf = fn
        end
        self.wakeReset = wakeReset
    end

    -- A world change: forget the capture and the reset watch without touching any of their objects
    -- (the capture widget and router die with the old world).
    function self.discardWorld()
        poll, watch, lastPanel = nil, nil, nil
        return true
    end

    function self.dispose()
        disposed = true
        press, reset = {}, {}
        if poll then
            local p = poll
            poll = nil
            unshield(p)
        end
        watch = nil
        return true
    end

    return self
end

return Keys
