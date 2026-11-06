-- UE4SS port adapted from the existing native-menu prototype.
local Events = {}
-- One UE4SS hook per receiver function and Lua state, registered once and never unregistered;
-- scopes only add and remove routes keyed by receiver address. The table is global so a reloaded
-- module keeps the hooks. (The crashes once blamed on hook churn were the receiver sub-path copy
-- described in bind(); research/2026-11-04-UE4SS功能等价验收/UE4SS委托绑定崩溃会诊-20261105.md.)
local HUB = '__PBZ_MODCONFIG_HOOKS_V1__'
local function hub()
    local shared = rawget(_G, HUB)
    if not shared then shared = {paths = {}}; rawset(_G, HUB, shared) end
    return shared
end

local function valid(object)
    return object ~= nil and object:IsValid()
end

-- While a world changes no callback runs: a slider released or a rotator stepped during the load would
-- otherwise call into widgets of the old world (review 2026-11-05). The runtime pauses on LoadMapPre and
-- resumes when it touches panels again. Kept in the shared hub so a reloaded copy sees the same state.
function Events.pause(paused)
    hub().paused = paused == true
    return true
end
function Events.paused() return hub().paused == true end

-- fault(err) is optional: a callback of ours that raised means the page's native state can no longer be
-- trusted (JS NativeSupport.lifetime), so the owner retires the page instead of calling on.
-- lost() is optional: called once when a callback finds the owner, a sender or a receiver dead. The whole
-- scope is then forgotten in Lua, and the owner must forget every other use of those widgets at once
-- (review 2026-11-05, round 8: one control carried two bindings and was cached by its row).
function Events.create(owner, host, report, fault, lost)
    local active = true
    local bindings = {}
    local mine = {}

    -- Returns the shared route table of `path`, registering its hook on first use.
    local function listen(path)
        local shared = hub()
        local entry = shared.paths[path]
        if not entry then
            local routes = {}
            entry = {routes = routes}
            entry.ids = {RegisterHook(path, function(context, value)
                local found, object = pcall(function() return context:get() end)
                if not found or not valid(object) then return end
                local addressed, address = pcall(function() return object:GetAddress() end)
                local route = addressed and routes[address] or nil
                if route then route(value) end
            end)}
            shared.paths[path] = entry
        end
        return entry.routes
    end

    local scope = {}

    local function bind(delegate, className, functionName, callback, sender)
        assert(active, "EVENT_SCOPE_DISPOSED")
        local path = "/Script/UMG." .. className .. ":" .. functionName
        local class = StaticFindObject("/Script/UMG." .. className)
        assert(valid(class), "EVENT_RECEIVER_CLASS_MISSING")
        -- Outered directly to the transient package, never to a widget tree: the first weak reference
        -- made by delegate:Add copies the receiver's soft sub-path with a wrong element size in this
        -- UE4SS build (three crashes, see PbzMapNativeBind). An empty sub-path copies nothing.
        local transient = StaticFindObject("/Engine/Transient")
        assert(transient and transient:IsValid(), "EVENT_TRANSIENT_PACKAGE_MISSING")
        local receiver = StaticConstructObject(class, transient, 0, 0x40)
        assert(valid(receiver), "EVENT_RECEIVER_CREATION_FAILED")
        receiver:SetVisibility(1)
        host:AddChild(receiver)
        local routes = listen(path)
        local address = receiver:GetAddress()
        local binding = {delegate = delegate, sender = sender, receiver = receiver, name = functionName, routes = routes, address = address}
        bindings[#bindings + 1] = binding
        local function route(value)
            if not active or hub().paused then return end
            if not valid(owner) or not valid(receiver) or (sender ~= nil and not valid(sender)) then
                -- Found dead: every binding of the scope is forgotten for good, so no later callback or
                -- release reaches a delegate or widget through an address that may belong to another
                -- object by then; the owner hears it and forgets its own uses.
                scope.discardWorld()
                if lost then
                    local told, err = pcall(lost)
                    if not told then report("INPUT_LOSS_HANDLER_FAILED", err) end
                end
                return
            end
            local ok, err = xpcall(function()
                callback(value and value:get() or nil)
            end, debug.traceback)
            if not ok then
                report("INPUT_CALLBACK_FAILED", err)
                if fault then fault(err) end
            end
        end
        routes[address], binding.route = route, route
        mine[#mine + 1] = binding
        local ok, err = pcall(function() delegate:Add(receiver, functionName) end)
        if not ok then
            routes[address] = nil
            receiver:RemoveFromParent()
            error(err)
        end
        return receiver
    end

    function scope.bindClick(delegate, callback, sender)
        -- UE4SS 1195 delegate lookup does not search parent classes. These
        -- receiver functions must be declared on their concrete native class.
        return bind(delegate, "SizeBox", "ClearWidthOverride", callback, sender)
    end

    function scope.bindNumber(delegate, callback, sender)
        return bind(delegate, "Slider", "SetValue", callback, sender)
    end

    function scope.bindKey(delegate, callback, sender)
        return bind(delegate, "InputKeySelector", "SetSelectedKey", callback, sender)
    end

    -- A world change took the owner: forget every route and binding in Lua only. The receivers and
    -- delegates belong to the old world and are never touched; the hooks stay (see the top of this file).
    function scope.discardWorld()
        active = false
        for _, binding in ipairs(mine) do
            if binding.routes[binding.address] == binding.route then binding.routes[binding.address] = nil end
        end
        mine, bindings = {}, {}
        return true
    end

    -- Returns true once every binding and hook is released. A failed step stays queued, so a later
    -- call retries only what is left; callers must not report the owner as released on false.
    function scope.dispose()
        -- A dead owner took its widgets with it: nothing of the scope is released natively.
        if not valid(owner) then return scope.discardWorld() end
        active = false
        for _, binding in ipairs(mine) do binding.routes[binding.address] = nil end
        mine = {}
        local clean = true
        local remaining = {}
        for i = #bindings, 1, -1 do
            local binding = bindings[i]
            local ok, err = pcall(function()
                if binding.lost then return end
                -- Without a live sender the delegate is never touched again, also not by a retry: the
                -- detached receiver is weakly bound and goes with the next collection.
                if binding.delegate and not (binding.sender ~= nil and valid(binding.sender)) then
                    binding.delegate, binding.sender = nil, nil
                end
                if not valid(binding.receiver) then
                    binding.lost, binding.receiver, binding.delegate = true, nil, nil
                    return
                end
                if binding.delegate then
                    binding.delegate:Remove(binding.receiver, binding.name)
                    binding.delegate = nil
                end
                binding.receiver:RemoveFromParent()
            end)
            if not ok then
                clean = false
                remaining[#remaining + 1] = binding
                report("INPUT_RELEASE_FAILED", err)
            end
        end
        bindings = {}
        for i = #remaining, 1, -1 do bindings[#bindings + 1] = remaining[i] end
        -- The hooks stay registered (see the top of this file); only our routes were removed.
        return clean
    end

    return scope
end

return Events
