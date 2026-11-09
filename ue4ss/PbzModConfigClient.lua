-- ModConfig client for third-party UE4SS mods. Copy this file (and
-- PbzConfigCore.lua, or the bundled single-file build) into your mod's Scripts
-- directory. Your mod keeps owning its settings and files; ModConfig only shows
-- them. Each UE4SS mod has its own Lua state, so nothing here shares functions
-- or tables: the two sides exchange JSON strings through ModRef shared
-- variables and everything runs on the game thread. See CROSS_MOD_PROTOCOL.md.
--
--   local Client = require('PbzModConfigClient')
--   local handle = Client.register(provider)   -- provider: same shape as the JS descriptor
--   -- on unload: handle.close()
local Core = require("PbzConfigCore")
local json = Core.json

local Client = {PROTOCOL = 1}
local PREFIX = "PbzMC1."
local LIMIT = 262144
Client.names = {
    host = PREFIX .. "host",
    index = PREFIX .. "idx",
    schema = function(modId) return PREFIX .. "s." .. modId end,
    up = function(modId) return PREFIX .. "u." .. modId end,
    down = function(modId) return PREFIX .. "d." .. modId end,
}

local counter = 0
function Client.newInstance()
    counter = counter + 1
    local seed = string.format("%x%x%x", os.time() % 0xffffff, math.floor((os.clock() * 1000) % 0xffffff), counter)
    local cell = {}
    local address = tostring(cell):match("0x(%x+)") or tostring(cell):match("(%x+)$") or "0"
    return ("c" .. seed .. address .. string.format("%08x", math.random(0, 0x7fffffff))):sub(1, 48)
end

local function validToken(value)
    return type(value) == "string" and #value >= 8 and #value <= 64 and value:match("^[A-Za-z0-9_-]+$") ~= nil
end
Client.validToken = validToken

-- Adapter over ModRef. Shared variables only hold strings here and are never
-- cleared with nil or retyped: UE4SS stores each value in a typed heap cell and
-- replaces it without checking the previous type.
function Client.modRefShared(modRef)
    modRef = modRef or rawget(_G, "ModRef")
    assert(modRef ~= nil, "MODREF_UNAVAILABLE")
    return {
        get = function(name) return modRef:GetSharedVariable(name) end,
        set = function(name, value) modRef:SetSharedVariable(name, value) end,
    }
end

local function safeGet(shared, name)
    local value = shared.get(name)
    if value == nil then return nil end
    if type(value) ~= "string" then error("SHARED_VARIABLE_FOREIGN_TYPE " .. name, 0) end
    return value
end

local function safeSet(shared, name, value)
    assert(type(value) == "string" and #value <= LIMIT, "SHARED_VALUE_INVALID")
    safeGet(shared, name) -- refuses to retype a variable another mod filled with a non-string
    shared.set(name, value)
end

local function defaultSchedule(fn, delayMs)
    assert(type(ExecuteInGameThreadWithDelay) == "function", "GAME_THREAD_SCHEDULER_UNAVAILABLE")
    return ExecuteInGameThreadWithDelay(delayMs, fn)
end

local function defaultCancel(handle)
    if type(CancelDelayedAction) == "function" and handle ~= nil then pcall(CancelDelayedAction, handle) end
end

local function plainData(value)
    local ok = pcall(Core.copy, value)
    return ok
end

local function descriptorOf(provider)
    local descriptor = {
        apiVersion = 1, modId = provider.modId, modVersion = provider.modVersion or "",
        schemaVersion = provider.schemaVersion, displayName = provider.displayName,
        groups = provider.groups, entries = provider.entries,
    }
    descriptor = Core.copy(descriptor)
    return descriptor, Core.compile(descriptor)
end

local function resultOf(id, result)
    local item = {id = id, ok = type(result) == "table" and result.ok == true}
    if type(result) ~= "table" then item.err = "INVALID_RESULT"; item.ok = false; return item end
    if not item.ok then item.err = type(result.error) == "string" and result.error:sub(1, 64) or "FAILED" end
    if type(result.fields) == "table" and plainData(result.fields) then item.fields = result.fields end
    if type(result.revision) == "number" then item.rev = result.revision end
    if type(result.durationMs) == "number" then item.dur = result.durationMs end
    return item
end

function Client.register(provider, options)
    options = options or {}
    assert(type(provider) == "table" and Core.validId(provider.modId), "CLIENT_PROVIDER_INVALID")
    for _, name in ipairs({"read", "apply", "reset", "flush", "subscribe"}) do
        assert(type(provider[name]) == "function", "CLIENT_PROVIDER_MISSING " .. name)
    end
    local modId = provider.modId
    local shared = options.shared or Client.modRefShared()
    local now = options.now or os.clock
    local schedule, cancel = options.schedule or defaultSchedule, options.cancel or defaultCancel
    local interval = options.intervalMs or 100
    local idleInterval = options.idleMs or 1000
    local ttl = options.ttl or 10
    local heartbeat = options.heartbeat or 1
    local report = options.report or function(code, detail)
        print("[PbzModConfigClient] " .. tostring(code) .. " " .. tostring(detail or "") .. "\n")
    end
    local function log(code, detail) pcall(report, code, detail) end

    local descriptor, schema = descriptorOf(provider)
    local instance = options.instance or Client.newInstance()
    assert(validToken(instance), "CLIENT_INSTANCE_INVALID")
    local schemaRaw = json.encode(json.object({p = 1, i = instance, sn = 1, d = descriptor}))
    assert(#schemaRaw <= LIMIT, "CLIENT_SCHEMA_TOO_LARGE")

    local self = {instance = instance}
    local closed, timer = false, nil
    local hostBeat, hostChanged, hostId, hostClosed = nil, nil, nil, false
    local lastDown, lastCmd, lastHostId = nil, 0, nil
    local results, upRaw, upBody, lastWrite, beat = {}, nil, nil, -math.huge, 0
    local dirty, verifyAt = true, -math.huge
    local activeStop, previewDeadline
    local unsubscribe
    local fault

    local function stopPreview()
        local stop = activeStop
        activeStop, previewDeadline = nil, nil
        if stop then
            local ok, err = pcall(stop)
            if not ok then log("PREVIEW_STOP_FAILED", err) end
        end
    end

    local function current()
        local ok, snapshot = pcall(provider.read)
        if not ok or type(snapshot) ~= "table" or type(snapshot.values) ~= "table"
            or type(snapshot.revision) ~= "number" or snapshot.revision < 0 or snapshot.revision % 1 ~= 0 then
            if fault ~= "READ_FAILED" then log("CLIENT_READ_FAILED", ok and "INVALID_SNAPSHOT" or snapshot) end
            fault = "READ_FAILED"
            return nil
        end
        fault = nil
        return snapshot
    end

    local function execute(command)
        local op, id = command.op, command.id
        local snapshot = current()
        if not snapshot then return {id = id, ok = false, err = "PROVIDER_FAILED"} end
        local context = {baseRevision = type(command.base) == "number" and command.base or nil, origin = "PbzModConfig"}
        if context.baseRevision ~= nil and context.baseRevision ~= snapshot.revision then
            return {id = id, ok = false, err = "REVISION_CONFLICT"}
        end
        if op == "apply" then
            if not json.isObject(command.patch) then return {id = id, ok = false, err = "VALIDATION_FAILED"} end
            local errors = Core.validatePatch(schema, command.patch, snapshot.values)
            if next(errors) ~= nil then return {id = id, ok = false, err = "VALIDATION_FAILED", fields = errors} end
            for key in pairs(command.patch) do
                local entry = schema.entries[key]
                if not Core.enabled(entry, snapshot.values) or not Core.visible(entry, snapshot.values) then
                    return {id = id, ok = false, err = "DISABLED"}
                end
            end
            stopPreview()
            return resultOf(id, provider.apply(Core.copy(command.patch), context))
        elseif op == "reset" then
            if command.group ~= nil and (type(command.group) ~= "string" or not schema.groups[command.group]) then
                return {id = id, ok = false, err = "UNKNOWN_GROUP"}
            end
            stopPreview()
            return resultOf(id, provider.reset(command.group, context))
        elseif op == "flush" then
            return resultOf(id, provider.flush())
        elseif op == "action" then
            local entry = type(command.key) == "string" and schema.entries[command.key] or nil
            if not entry or entry.type ~= "action" or type(provider.invokeAction) ~= "function" then
                return {id = id, ok = false, err = "UNKNOWN_ACTION"}
            end
            if not Core.enabled(entry, snapshot.values) or not Core.visible(entry, snapshot.values) then
                return {id = id, ok = false, err = "DISABLED"}
            end
            local action = provider.invokeAction(command.key, context)
            local result = resultOf(id, action)
            if result.ok and action.message ~= nil then
                assert(Core.isText(action.message), "INVALID_ACTION_MESSAGE")
                result.msg = Core.copy(action.message)
            end
            return result
        elseif op == "preview" then
            stopPreview()
            local entry = type(command.key) == "string" and schema.entries[command.key] or nil
            if not entry or entry.type ~= "sound" or type(provider.previewSound) ~= "function" then
                return {id = id, ok = false, err = "PREVIEW_UNAVAILABLE"}
            end
            if not Core.enabled(entry, snapshot.values) or not Core.visible(entry, snapshot.values) then
                return {id = id, ok = false, err = "DISABLED"}
            end
            local started = provider.previewSound(command.key, context)
            if type(started) ~= "table" or started.ok ~= true or type(started.stop) ~= "function" then
                return {id = id, ok = false, err = type(started) == "table" and type(started.error) == "string"
                    and started.error:sub(1, 64) or "PREVIEW_FAILED"}
            end
            activeStop = started.stop
            -- The owner stops the sound on request; this is only a backstop if the menu dies.
            previewDeadline = now() + (type(started.durationMs) == "number" and math.max(50, math.min(5000, started.durationMs)) or 5000) / 1000 + 1
            return {id = id, ok = true, dur = started.durationMs}
        elseif op == "stop" then
            stopPreview()
            return {id = id, ok = true}
        end
        return {id = id, ok = false, err = "UNKNOWN_OPERATION"}
    end

    local function processCommands(raw)
        local down = json.decode(raw, LIMIT)
        if type(down) ~= "table" or down.p ~= 1 or down.i ~= instance or not validToken(down.h) or not json.isArray(down.cmds) then
            return
        end
        if down.h ~= lastHostId then lastHostId, lastCmd, results = down.h, 0, {} end
        for _, command in ipairs(down.cmds) do
            if json.isObject(command) and math.type(command.id) == "integer" and command.id > lastCmd and type(command.op) == "string" then
                local ok, result = pcall(execute, command)
                if not ok then
                    log("CLIENT_COMMAND_FAILED", result)
                    result = {id = command.id, ok = false, err = "PROVIDER_FAILED"}
                end
                lastCmd = command.id
                results[#results + 1] = result
                while #results > 16 do table.remove(results, 1) end
                dirty = true
            end
        end
    end

    local function publish(t, force)
        local snapshot = current()
        local body
        if snapshot then
            local persistence = type(snapshot.persistence) == "table" and snapshot.persistence or {}
            body = {p = 1, i = instance, sn = 1, ah = lastHostId or json.null, ack = lastCmd,
                snap = json.object({rev = snapshot.revision, values = json.object(Core.copy(snapshot.values)),
                    ps = persistence.state or "saved", pe = persistence.error ~= nil and tostring(persistence.error):sub(1, 120) or json.null}),
                res = json.array(Core.copy(results)), f = json.null}
        else
            body = {p = 1, i = instance, sn = 1, ah = lastHostId or json.null, ack = lastCmd, snap = json.null,
                res = json.array(Core.copy(results)), f = fault or "READ_FAILED"}
        end
        local text = json.encode(json.object(body))
        if text ~= upBody or force or t - lastWrite >= heartbeat then
            beat = beat + 1
            body.beat = beat
            local raw = json.encode(json.object(body))
            assert(#raw <= LIMIT, "CLIENT_SNAPSHOT_TOO_LARGE")
            safeSet(shared, Client.names.up(modId), raw)
            upBody, upRaw, lastWrite = text, raw, t
        end
        dirty = false
    end

    local function ensureRegistered(t)
        local index = safeGet(shared, Client.names.index)
        if not index or not index:find(";" .. modId .. ";", 1, true) then
            index = (index and index ~= "" and index or ";") .. modId .. ";"
            assert(#index <= 8192, "CLIENT_INDEX_FULL")
            safeSet(shared, Client.names.index, index)
        end
        if safeGet(shared, Client.names.schema(modId)) ~= schemaRaw then safeSet(shared, Client.names.schema(modId), schemaRaw) end
        verifyAt = t + 5
    end

    local function tick()
        timer = nil
        if closed then return end
        local ok, err = xpcall(function()
            local t = now()
            local hostRaw = safeGet(shared, Client.names.host)
            if hostRaw then
                local info = json.decode(hostRaw, 4096)
                if type(info) == "table" and info.p == 1 and validToken(info.host) then
                    if info.beat ~= hostBeat or info.host ~= hostId then hostBeat, hostId, hostChanged = info.beat, info.host, t end
                    hostClosed = info.closed == true
                end
            end
            local hostAlive = hostChanged ~= nil and not hostClosed and t - hostChanged <= ttl
            self.hostAlive = hostAlive
            if t >= verifyAt then ensureRegistered(t) end
            if previewDeadline and t > previewDeadline then stopPreview() end
            if hostAlive then
                local raw = safeGet(shared, Client.names.down(modId))
                if raw and raw ~= lastDown then lastDown = raw; processCommands(raw) end
            end
            if dirty or t - lastWrite >= heartbeat then publish(t, false) end
        end, debug.traceback)
        if not ok then
            log("CLIENT_TICK_FAILED", err)
            verifyAt = -math.huge
        end
        if not closed then timer = schedule(tick, self.hostAlive and interval or idleInterval) end
    end

    function self.tick() tick() end
    function self.status()
        return {instance = instance, hostAlive = self.hostAlive == true, closed = closed, lastCommand = lastCmd, fault = fault}
    end
    function self.close()
        if closed then return false end
        closed = true
        if timer ~= nil then cancel(timer); timer = nil end
        stopPreview()
        if unsubscribe then pcall(unsubscribe) end
        pcall(function()
            local ok, err = pcall(provider.flush)
            if not ok then log("CLIENT_FLUSH_FAILED", err) end
            local snapshot = current()
            local body = {p = 1, i = instance, sn = 1, ah = lastHostId or json.null, ack = lastCmd, closed = true,
                snap = snapshot and json.object({rev = snapshot.revision, values = json.object(Core.copy(snapshot.values)),
                    ps = "saved", pe = json.null}) or json.null, res = json.array({}), beat = beat + 1}
            safeSet(shared, Client.names.up(modId), json.encode(json.object(body)))
        end)
        return true
    end

    unsubscribe = provider.subscribe(function() dirty = true end)
    if type(unsubscribe) ~= "function" then unsubscribe = nil end
    local first, firstErr = pcall(function()
        timer = schedule(tick, 0)
    end)
    if not first then closed = true; error(firstErr, 0) end
    return self
end

-- Convenience: build the generic Lua store (PbzConfigStore.lua) and register it.
function Client.createStore(descriptor, storeOptions)
    return require("PbzConfigStore").create(descriptor, storeOptions)
end

return Client
