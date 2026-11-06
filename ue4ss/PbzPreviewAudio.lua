-- Sound-preview support. Port of Framework.js preview() and native/NativePreviewAudio.js.
-- Nothing here touches the engine unless the caller injects an `api`; the
-- native adapter is optional and stays disabled until a probe confirms it.
local Audio = {}

local function noop() end
local function valid(object) return object ~= nil and object:IsValid() end

---------------------------------------------------------------------------
-- Playback ownership: one preview at a time, always stoppable.
---------------------------------------------------------------------------
-- request = {owner=<identity>, key=<entry key>, value=<current value>,
--            play=function() -> {ok, stop, durationMs, error}, beginAudioFocus=function() -> restore|nil}
function Audio.createPlayback(options)
    options = options or {}
    local report = options.report or noop
    local function log(code, detail) pcall(report, code, detail) end
    local generation, current = 0, nil
    local self = {}

    function self.stop()
        generation = generation + 1
        local old = current
        current = nil
        if old then
            local ok, err = pcall(old.stop)
            if ok then log("SOUND_PREVIEW_STOPPED", old.key) else log("PREVIEW_STOP_FAILED", tostring(err)) end
        end
        return generation
    end

    function self.start(request)
        local mine = self.stop()
        local restore, result, owned = nil, nil, false
        local function release()
            local fn = restore
            restore = nil
            if type(fn) == "function" then
                local ok, err = pcall(fn)
                if not ok then log("PREVIEW_AUDIO_RESTORE_FAILED", tostring(err)) end
            end
        end
        local function stopOwned()
            local ok, err = pcall(function()
                if owned then owned = false; result.stop() end
            end)
            release()
            if not ok then error(err, 0) end
        end
        local ok, outcome = pcall(function()
            local focus = request.beginAudioFocus or options.beginAudioFocus
            if type(focus) == "function" then restore = focus() end
            if mine ~= generation then release(); return {ok = false, error = "PREVIEW_CHANGED"} end
            log("SOUND_PREVIEW_REQUESTED", request.key)
            result = request.play()
            if type(result) ~= "table" or result.ok ~= true or type(result.stop) ~= "function" then
                release()
                local reason = type(result) == "table" and result.error or "PREVIEW_FAILED"
                log("SOUND_PREVIEW_REJECTED", tostring(reason))
                return {ok = false, error = reason}
            end
            owned = true
            -- Close/cover may run inside the owner's start callback, before its stop
            -- function exists. Do not resurrect that cancelled start.
            if mine ~= generation then stopOwned(); return {ok = false, error = "PREVIEW_CHANGED"} end
            current = {owner = request.owner, key = request.key, value = request.value, stop = stopOwned}
            log("SOUND_PREVIEW_STARTED", request.key)
            local duration = result.durationMs
            if type(duration) ~= "number" or duration ~= duration or duration == math.huge or duration == -math.huge then
                duration = 5000
            end
            return {ok = true, durationMs = math.max(50, math.min(5000, duration))}
        end)
        if ok then return outcome end
        local cleaned, cleanup = pcall(function()
            if current and current.stop == stopOwned then self.stop() else stopOwned() end
        end)
        if not cleaned then log("PREVIEW_STOP_FAILED", tostring(cleanup)) end
        log("PREVIEW_FAILED", tostring(outcome))
        return {ok = false, error = "PREVIEW_FAILED"}
    end

    -- Stop when the previewed value changed or its row became unusable.
    -- stillValid(key, value) -> boolean.
    function self.reconcile(owner, stillValid)
        if current and current.owner == owner and not stillValid(current.key, current.value) then self.stop() end
    end

    function self.fault(owner)
        if current and current.owner == owner then self.stop() end
    end

    function self.active() return current and {owner = current.owner, key = current.key} or nil end
    return self
end

---------------------------------------------------------------------------
-- Background ducking while a preview plays: only the live mix changes.
---------------------------------------------------------------------------
-- api = {settings=function() -> table with the channel fields, setVolume=function(type, value),
--        channels={{field="MusicVolume", type=<enum>}, {field="AmbientVolume", type=<enum>}}}
local mixes = setmetatable({}, {__mode = "k"})

local function volume(value) return type(value) == "number" and value == value and value >= 0 and value <= 1 end

function Audio.beginFocus(api, report)
    local function notify(event) pcall(report or noop, "PREVIEW_AUDIO_FOCUS", event) end
    local changed, ended, settings, mix = {}, false, nil, nil
    local function restoreChannels()
        if api.valid and not api.valid(settings) then changed, settings = {}, nil; return end
        for index = #changed, 1, -1 do
            local channel = table.remove(changed, index)
            local ok, err = pcall(function()
                -- Respect a real preference edited during this short lease.
                local live = settings[channel.field]
                local value = volume(live) and live or channel.before
                api.setVolume(channel.type, value)
                notify({stage = "restored", channel = channel.field, value = value})
            end)
            if not ok then notify({stage = "restore_failed", channel = channel.field, detail = tostring(err)}) end
        end
    end
    local function restore()
        if ended then return end
        ended = true
        if mix then
            mix.users = mix.users - 1
            if mix.users > 0 then return end
            mixes[settings] = nil
            mix.restore()
            return
        end
        restoreChannels()
    end
    local ok, err = pcall(function()
        settings = api.settings()
        if not settings or (api.valid and not api.valid(settings)) or type(api.setVolume) ~= "function" then error("AUDIO_VOLUME_UNAVAILABLE", 0) end
        local existing = mixes[settings]
        if existing then mix = existing; mix.users = mix.users + 1; return end
        -- Validate all readbacks before changing either channel.
        for _, channel in ipairs(api.channels) do
            channel.before = settings[channel.field]
            if not volume(channel.before) or channel.type == nil then error("AUDIO_VOLUME_READBACK_UNAVAILABLE", 0) end
        end
        for _, channel in ipairs(api.channels) do
            changed[#changed + 1] = channel
            api.setVolume(channel.type, channel.before * 0.2)
            notify({stage = "lowered", channel = channel.field, before = channel.before, value = channel.before * 0.2})
        end
        mix = {users = 1, restore = restoreChannels}
        mixes[settings] = mix
    end)
    if not ok then restore(); notify({stage = "unavailable", detail = tostring(err)}) end
    return restore
end

-- Optional adapter for the shipping game. Unconfirmed in UE4SS: class names, the
-- local-player accessor and the enum values come from the JS build 26266538 code.
-- `env` supplies find(path), context (any live widget), libraries and enums.
function Audio.nativeApi(env)
    local context = env.context
    assert(context ~= nil and env.find, "AUDIO_CONTEXT_MISSING")
    local library = env.find("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
    local subsystems = env.find("/Script/Engine.Default__SubsystemBlueprintLibrary")
    local class = env.find("/Script/ProjectPBZ.PBZSoundFXSubsystem")
    assert(library and subsystems and class, "AUDIO_CLASSES_UNAVAILABLE")
    local enum = env.enum
    assert(type(enum) == "table" and enum.MusicVolume ~= nil and enum.AmbVolume ~= nil, "AUDIO_ENUM_UNAVAILABLE")
    local sound, unavailable
    return {
        valid = valid,
        settings = function()
            if not valid(context) or not valid(library) then context, library = nil, nil; return nil end
            local player = library:GetLocalPlayer(context)
            return valid(player) and player:GetSharedSettings() or nil
        end,
        setVolume = function(kind, value)
            if unavailable then return end
            if sound and not valid(sound) then sound, unavailable = nil, true; return end
            if not sound then
                if not valid(context) or not valid(subsystems) or not valid(class) then return end
                sound = subsystems:GetWorldSubsystem(context, class)
            end
            if not valid(sound) then sound = nil; return end
            sound:SetAudioVolume(kind, value)
        end,
        channels = {{field = "MusicVolume", type = enum.MusicVolume}, {field = "AmbientVolume", type = enum.AmbVolume}},
    }
end

return Audio
