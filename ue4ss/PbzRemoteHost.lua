-- Host side of the cross-mod protocol (CROSS_MOD_PROTOCOL.md). Every third-party
-- mod that registered through PbzModConfigClient shows up here as an ordinary
-- provider backed by a message proxy: values are optimistic until the owner
-- mod confirms them, and the owner stays the only writer of its own files.
local Core = require("PbzConfigCore")
local Client = require("PbzModConfigClient")
local json = Core.json

local Remote = {SLOT = "__PBZ_REMOTE_HOST_V1__"}
local LIMIT = 262144
local MAX_CLIENTS, MAX_PENDING = 64, 64

local function copyValues(values)
    local result = {}
    for key, value in pairs(values) do result[key] = value end
    return result
end

local function persistenceOf(state, error)
    local result = {state = state}
    if error ~= nil then result.error = error end
    return result
end

local function sameValues(left, right)
    for key, value in pairs(left) do if right[key] ~= value then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

local function createProxy(deps, modId, descriptor, schema, hostId, instance)
    local server, pending, outbox = nil, {}, {}
    local nextId, alive, asyncError = 1, true, nil
    local settled = 0 -- highest command id whose result has been taken in
    local shown = nil -- the last {revision, values} handed out
    local listeners, nextListener = {}, 0
    local provider = {apiVersion = 1, modId = modId, modVersion = descriptor.modVersion or "", async = true, remote = true,
        schemaVersion = descriptor.schemaVersion, displayName = descriptor.displayName,
        groups = descriptor.groups, entries = descriptor.entries}

    -- The menu requires a revision that never goes back (JS Framework.read). Optimistic edits
    -- count ahead of the owner, so an edit the owner refuses would step back: in game a binding
    -- that raced the owner's own change (REVISION_CONFLICT) left the mod's page unreadable,
    -- "暂不可用", until the menu was reopened (2026-11-05). Values that changed without the
    -- revision moving ahead get the next number instead.
    local function view()
        assert(server, "REMOTE_NOT_READY")
        local values, revision = copyValues(server.values), server.rev
        for _, item in ipairs(pending) do
            if item.patch then
                for key, value in pairs(item.patch) do values[key] = value end
                if item.bump then revision = revision + 1 end
            end
        end
        if shown == nil or revision > shown.revision then shown = {revision = revision, values = values}
        elseif not sameValues(values, shown.values) then shown = {revision = shown.revision + 1, values = values} end
        local persistence = #pending > 0 and persistenceOf("pending") or persistenceOf(server.ps, server.pe)
        return {revision = shown.revision, values = copyValues(values), persistence = persistence}
    end
    local function notify(origin)
        if not alive or not server then return end
        local queued = {}
        for _, item in ipairs(listeners) do queued[#queued + 1] = item end
        for _, item in ipairs(queued) do
            local event = view()
            event.origin = origin
            local ok, err = pcall(item.callback, event)
            if not ok then pcall(deps.report, "REMOTE_LISTENER_FAILED", err) end
        end
    end
    local function result(ok, error, fields)
        local value = view()
        value.ok = ok
        if error then value.error, value.fields = error, fields end
        return value
    end
    local function enqueue(command)
        if #outbox >= MAX_PENDING then return false end
        command.id = nextId
        nextId = nextId + 1
        outbox[#outbox + 1] = command
        return command
    end

    function provider.read() return view() end
    function provider.subscribe(callback)
        assert(type(callback) == "function", "PROVIDER_LISTENER_INVALID")
        nextListener = nextListener + 1
        local item = {id = nextListener, callback = callback}
        listeners[#listeners + 1] = item
        return function()
            for index, value in ipairs(listeners) do
                if value.id == item.id then table.remove(listeners, index); return true end
            end
            return false
        end
    end

    local function submit(op, patch, group, context)
        if not alive then return result(false, "STALE_PROVIDER") end
        local current = view()
        context = type(context) == "table" and context or {}
        if context.baseRevision ~= nil and context.baseRevision ~= current.revision then return result(false, "REVISION_CONFLICT") end
        local errors = Core.validatePatch(schema, patch, current.values)
        if next(errors) ~= nil then return result(false, "VALIDATION_FAILED", errors) end
        for key in pairs(patch) do
            local entry = schema.entries[key]
            if not Core.enabled(entry, current.values) or not Core.visible(entry, current.values) then return result(false, "DISABLED") end
        end
        local changed = false
        for key, value in pairs(patch) do if current.values[key] ~= value then changed = true end end
        if not changed then return result(true) end
        local last = outbox[#outbox]
        if op == "apply" and last and last.op == "apply" and not last.sent and not last.base then
            for key, value in pairs(patch) do last.patch[key] = value end
            for _, item in ipairs(pending) do
                if item.id == last.id then for key, value in pairs(patch) do item.patch[key] = value end end
            end
            notify(context.origin)
            return result(true)
        end
        -- With earlier commands in flight the expected owner revision is unknown, so no check is sent.
        local command = enqueue({op = op, patch = copyValues(patch), group = group, base = #pending == 0 and server.rev or nil})
        if not command then return result(false, "REMOTE_BUSY") end
        pending[#pending + 1] = {id = command.id, patch = copyValues(patch), bump = true}
        notify(context.origin)
        return result(true)
    end

    function provider.apply(patch, context)
        if not json.isObject(patch) then return result(false, "VALIDATION_FAILED", {_patch = "EXPECTED_OBJECT"}) end
        return submit("apply", patch, nil, context)
    end

    function provider.reset(groupId, context)
        if groupId ~= nil and not schema.groups[groupId] then return result(false, "UNKNOWN_GROUP") end
        local patch = {}
        for _, entry in ipairs(schema.valueList) do
            if groupId == nil or entry.group == groupId then patch[entry.key] = entry.defaultValue end
        end
        return submit("reset", patch, groupId, context)
    end

    function provider.flush()
        if not alive then return result(false, "STALE_PROVIDER") end
        local last = outbox[#outbox]
        if not (last and last.op == "flush" and not last.sent) then
            if not enqueue({op = "flush"}) then return result(false, "REMOTE_BUSY") end
        end
        return result(true)
    end

    function provider.invokeAction(key, context)
        if not alive then return result(false, "STALE_PROVIDER") end
        local current = view()
        context = type(context) == "table" and context or {}
        if context.baseRevision ~= nil and context.baseRevision ~= current.revision then return result(false, "REVISION_CONFLICT") end
        local entry = type(key) == "string" and schema.entries[key] or nil
        if not entry or entry.type ~= "action" then return result(false, "UNKNOWN_ACTION") end
        if not Core.enabled(entry, current.values) or not Core.visible(entry, current.values) then return result(false, "DISABLED") end
        if not enqueue({op = "action", key = key}) then return result(false, "REMOTE_BUSY") end
        return result(true)
    end

    function provider.previewSound(key, context)
        if not alive then return {ok = false, error = "STALE_PROVIDER"} end
        local current = view()
        context = type(context) == "table" and context or {}
        if context.baseRevision ~= nil and context.baseRevision ~= current.revision then return {ok = false, error = "REVISION_CONFLICT"} end
        local entry = type(key) == "string" and schema.entries[key] or nil
        if not entry or entry.type ~= "sound" then return {ok = false, error = "PREVIEW_UNAVAILABLE"} end
        if not Core.enabled(entry, current.values) or not Core.visible(entry, current.values) then return {ok = false, error = "DISABLED"} end
        if not enqueue({op = "preview", key = key}) then return {ok = false, error = "REMOTE_BUSY"} end
        local stopped = false
        return {ok = true, stop = function()
            if stopped then return end
            stopped = true
            if alive then enqueue({op = "stop"}) end
        end}
    end

    function provider.consumeAsyncError()
        local value = asyncError
        asyncError = nil
        return value
    end

    local proxy = {provider = provider}

    -- Merge a message from the owner. Results first: they decide which optimistic
    -- changes survive; the snapshot in the same message is the authority.
    function proxy.ingest(up)
        local acknowledged = (up.ah == hostId and math.type(up.ack) == "integer") and up.ack or 0
        local keep = {}
        for _, command in ipairs(outbox) do if command.id > acknowledged then keep[#keep + 1] = command end end
        outbox = keep
        local resolved = {}
        if json.isArray(up.res) then
            for _, item in ipairs(up.res) do
                if json.isObject(item) and math.type(item.id) == "integer" then
                    resolved[item.id] = item
                end
            end
        end
        local remaining = {}
        for _, item in ipairs(pending) do
            local answer = resolved[item.id]
            if answer then
                if answer.ok ~= true then asyncError = type(answer.err) == "string" and answer.err or "FAILED" end
            elseif item.id > acknowledged then remaining[#remaining + 1] = item end
        end
        pending = remaining
        -- Failures of non-value commands (actions, previews, flush) also need surfacing, once:
        -- the owner repeats its last results with every heartbeat.
        for id, answer in pairs(resolved) do
            if answer.ok ~= true and id <= acknowledged and id > settled and not asyncError then
                asyncError = type(answer.err) == "string" and answer.err or "FAILED"
            end
        end
        if acknowledged > settled then settled = acknowledged end
        local snap = up.snap
        if json.isObject(snap) and math.type(snap.rev) == "integer" and snap.rev >= 0 and json.isObject(snap.values)
            and (snap.ps == "saved" or snap.ps == "pending" or snap.ps == "failed") then
            local complete = true
            for _, entry in ipairs(schema.valueList) do
                if snap.values[entry.key] == nil or Core.valueError(entry, snap.values[entry.key]) then complete = false end
            end
            if complete then
                server = {rev = snap.rev, values = copyValues(snap.values), ps = snap.ps,
                    pe = type(snap.pe) == "string" and snap.pe or nil}
                notify("remote")
                return true
            end
            pcall(deps.report, "REMOTE_SNAPSHOT_INVALID", modId)
        end
        return server ~= nil
    end

    function proxy.ready() return server ~= nil end
    function proxy.down()
        local commands = json.array({})
        for _, command in ipairs(outbox) do
            local item = {id = command.id, op = command.op}
            if command.patch then item.patch = json.object(copyValues(command.patch)) end
            if command.group then item.group = command.group end
            if command.key then item.key = command.key end
            if command.base then item.base = command.base end
            commands[#commands + 1] = json.object(item)
        end
        return json.encode(json.object({p = 1, h = hostId, i = instance, cmds = commands}))
    end
    function proxy.markSent() for _, command in ipairs(outbox) do command.sent = true end end
    function proxy.hasOutbox() return #outbox > 0 end
    function proxy.dispose() alive = false; listeners = {} end
    return proxy
end

-- deps: shared{get,set}, host{providers(), registerProvider(provider)->handle}, schedule(fn,delayMs)->handle,
--       cancel(handle), now(), report(code,detail), hostId, ttl
function Remote.start(deps)
    assert(type(deps) == "table" and type(deps.shared) == "table" and type(deps.host) == "table"
        and type(deps.host.registerProvider) == "function" and type(deps.host.providers) == "function", "REMOTE_DEPS_INVALID")
    local shared, host = deps.shared, deps.host
    local now = deps.now or os.clock
    local schedule = deps.schedule or function(fn, delay) return ExecuteInGameThreadWithDelay(delay, fn) end
    local cancel = deps.cancel or function(handle) if type(CancelDelayedAction) == "function" and handle ~= nil then pcall(CancelDelayedAction, handle) end end
    local ttl, interval, idleInterval = deps.ttl or 10, deps.intervalMs or 50, deps.idleMs or 250
    local hostId = deps.hostId or Client.newInstance()
    assert(Client.validToken(hostId), "REMOTE_HOST_ID_INVALID")
    local function report(code, detail)
        if deps.report then pcall(deps.report, code, detail) end
    end
    local proxyDeps = {report = report}

    -- One remote host per Lua state; a reload (or a second start) retires the previous one first.
    local previous = rawget(_G, Remote.SLOT)
    if previous ~= nil then
        assert(type(previous) == "table" and type(previous.stop) == "function", "REMOTE_SLOT_ALREADY_OWNED")
        previous.stop()
    end
    local self, stopped, timer, beat, lastBeat = {hostId = hostId}, false, nil, 0, -math.huge
    local clients = {}

    local function get(name)
        local value = shared.get(name)
        if value == nil then return nil end
        assert(type(value) == "string", "SHARED_VARIABLE_FOREIGN_TYPE " .. name)
        return value
    end
    local function set(name, value)
        assert(type(value) == "string" and #value <= LIMIT, "SHARED_VALUE_INVALID")
        get(name)
        shared.set(name, value)
    end

    local function drop(client, why)
        if client.handle then
            local ok, err = pcall(client.handle.dispose)
            if not ok then report("REMOTE_DISPOSE_FAILED", err) end
            client.handle = nil
        end
        if client.proxy then client.proxy.dispose(); client.proxy = nil end
        if why then report("REMOTE_CLIENT_DROPPED", client.modId .. " " .. why) end
    end

    local function build(client, up)
        local raw = get(Client.names.schema(client.modId))
        local record = raw and json.decode(raw, LIMIT) or nil
        if type(record) ~= "table" or record.p ~= 1 or record.i ~= up.i or not json.isObject(record.d) then return false, "SCHEMA_UNAVAILABLE" end
        local descriptor = record.d
        if descriptor.modId ~= client.modId then return false, "SCHEMA_MODID_MISMATCH" end
        local ok, schema = pcall(Core.compile, descriptor, function(event) report("REMOTE_" .. tostring(event.code), client.modId) end)
        if not ok then return false, "SCHEMA_INVALID " .. tostring(schema) end
        for _, existing in ipairs(host.providers()) do
            if existing.modId == client.modId and not (existing.descriptor and existing.descriptor.remote == true) then
                return false, "MODID_RESERVED"
            end
        end
        client.proxy = createProxy(proxyDeps, client.modId, descriptor, schema, hostId, up.i)
        client.schema = schema
        return true
    end

    local function processClient(client, t)
        local raw = get(Client.names.up(client.modId))
        if not raw then return end
        if raw == client.deadRaw then return end
        if raw ~= client.upRaw then
            client.upRaw = raw
            local up = json.decode(raw, LIMIT)
            if type(up) ~= "table" or up.p ~= 1 or not Client.validToken(up.i) or math.type(up.beat) ~= "integer" then
                if not client.invalidReported then client.invalidReported = true; report("REMOTE_UP_INVALID", client.modId) end
                return
            end
            client.invalidReported = nil
            if up.i ~= client.instance then
                -- New process of the owner mod (or a hot reload): rebuild from scratch.
                drop(client)
                client.instance, client.blocked, client.lastBeat, client.lastChange = up.i, nil, nil, t
                client.downRaw = nil
            end
            if up.beat ~= client.lastBeat then client.lastBeat, client.lastChange = up.beat, t end
            if up.closed == true then
                drop(client)
                client.blocked = "CLOSED"
                return
            end
            if not client.blocked then
                if not client.proxy then
                    local ok, why = build(client, up)
                    if not ok then client.blocked = why; report("REMOTE_CLIENT_REJECTED", client.modId .. " " .. why) end
                end
                if client.proxy then
                    local ready = client.proxy.ingest(up)
                    if ready and not client.handle then
                        local registered, handle = pcall(host.registerProvider, client.proxy.provider)
                        if registered then client.handle = handle
                        else client.blocked = "REGISTER_FAILED"; report("REMOTE_CLIENT_REJECTED", client.modId .. " " .. tostring(handle)); drop(client) end
                    end
                end
            end
        end
        if client.lastChange and t - client.lastChange > ttl then
            if client.proxy or client.handle then drop(client, "TIMEOUT") end
            client.blocked = "TIMEOUT"
            client.deadRaw = client.upRaw -- rebuild only once the owner writes something new
            client.instance, client.upRaw, client.lastChange = nil, nil, nil
            return
        end
        if client.proxy then
            local down = client.proxy.down()
            if down ~= client.downRaw then
                set(Client.names.down(client.modId), down)
                client.downRaw = down
                client.proxy.markSent()
            end
        end
    end

    local function tick()
        timer = nil
        if stopped then return end
        local ok, err = xpcall(function()
            local t = now()
            if t - lastBeat >= 1 then
                beat = beat + 1
                set(Client.names.host, json.encode(json.object({p = 1, host = hostId, beat = beat})))
                lastBeat = t
            end
            local index = get(Client.names.index) or ""
            local seen, count = {}, 0
            for modId in index:gmatch("[^;]+") do
                if Core.validId(modId) and not seen[modId] then
                    seen[modId] = true
                    count = count + 1
                    if count > MAX_CLIENTS then report("REMOTE_TOO_MANY_CLIENTS", modId); break end
                    local client = clients[modId]
                    if not client then client = {modId = modId}; clients[modId] = client end
                    local processed, failure = pcall(processClient, client, t)
                    if not processed then
                        if client.lastError ~= tostring(failure) then report("REMOTE_CLIENT_FAILED", modId .. " " .. tostring(failure)) end
                        client.lastError = tostring(failure)
                    else client.lastError = nil end
                end
            end
            self.active = count > 0
        end, debug.traceback)
        if not ok then report("REMOTE_TICK_FAILED", err) end
        if not stopped then timer = schedule(tick, self.active and interval or idleInterval) end
    end

    function self.tick() tick() end
    function self.clients()
        local list = {}
        for modId, client in pairs(clients) do
            list[#list + 1] = {modId = modId, instance = client.instance, registered = client.handle ~= nil,
                blocked = client.blocked, ready = client.proxy and client.proxy.ready() or false}
        end
        table.sort(list, function(a, b) return a.modId < b.modId end)
        return list
    end
    -- Plugin contract of PbzSharedHost.attachPlugin: return true once fully stopped.
    function self.stop()
        if stopped then return true end
        stopped = true
        if timer ~= nil then cancel(timer); timer = nil end
        for _, client in pairs(clients) do drop(client) end
        clients = {}
        if rawget(_G, Remote.SLOT) == self then rawset(_G, Remote.SLOT, nil) end
        pcall(set, Client.names.host, json.encode(json.object({p = 1, host = hostId, beat = beat + 1, closed = true})))
        return true
    end

    rawset(_G, Remote.SLOT, self)
    timer = schedule(tick, 0)
    return self
end

return Remote
