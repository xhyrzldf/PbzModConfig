-- Port of src/Editors.js (ModConfig 0.3.13): transient editing sessions for key
-- bindings, colours and sound previews. Editing state never reaches the owner
-- until an explicit accept; every session is bound to a provider token and revision.
--
-- options:
--   host.edit(ref, value) -> {ok, error, fields}        (accept a value)
--   host.preview(ref, beginAudioFocus) -> {ok, durationMs, error}
--   host.stopPreview()
--   word(name) -> string,   refresh(),   schedule(fn, ms) -> handle,   cancel(handle)
--   compactSound  (sound = choice row with an inline speaker button)
--   keyCapture    "selector" (default; the row hosts an InputKeySelector, keybind rows are
--                  passed through untouched) or "session" (JS-style: action row + event capture)
--   beginAudioFocus() -> restore|nil,  palette (optional PbzColorPalette for setBrightness)
local Core = require("PbzConfigCore")
local Editors = {}

local FATAL = {REVISION_CONFLICT = true, STALE_PROVIDER = true, PROVIDER_FAILED = true, DISABLED = true}

local function integer(value) return type(value) == "number" and value % 1 == 0 end

function Editors.create(options)
    assert(type(options) == "table" and type(options.host) == "table" and type(options.word) == "function"
        and type(options.refresh) == "function", "EDITORS_OPTIONS_INVALID")
    local host, word, refresh = options.host, options.word, options.refresh
    local schedule, cancelTimer = options.schedule, options.cancel
    local sessionKeys = options.keyCapture == "session"
    local session, playing, timer, feedback, previewGeneration = nil, nil, nil, nil, 0
    local swallowed = {}
    local self = {}

    local function stop()
        previewGeneration = previewGeneration + 1
        if timer ~= nil and cancelTimer then pcall(cancelTimer, timer) end
        timer, playing = nil, nil
        host.stopPreview()
        return previewGeneration
    end

    local function cancel()
        session, feedback = nil, nil
        stop()
        refresh()
    end

    local function failure(id, result)
        local code
        if type(result.fields) == "table" then code = select(2, next(result.fields)) end
        feedback = {id = id, code = code or result.error or "EDIT_FAILED"}
    end

    local function current(model, ref)
        return model ~= nil and model.enabled ~= false and model.ownerToken == ref.ownerToken
            and model.baseRevision == ref.revision
    end

    local function reference(model)
        return {id = model.id, key = model.key, providerId = model.providerId, ownerToken = model.ownerToken,
            revision = model.baseRevision, control = model.control, pair = model.pair}
    end

    -- UE4SS addition: a keyboard binding may carry its controller companion (model.pair = {key, control,
    -- value}), shown and captured on the same row; a controller key goes to the companion.
    local function bound(value) return value ~= nil and value ~= "" end
    local function clearable(model)
        local pair = model.pair
        return (model.control.allowUnbound ~= false and bound(model.value))
            or (pair ~= nil and pair.control.allowUnbound ~= false and bound(pair.value))
    end

    local function child(model, suffix, properties)
        local result = {}
        for key, value in pairs(model) do result[key] = value end
        result.id, result.parentId = model.id .. "/@" .. suffix, model.id
        for key, value in pairs(properties) do result[key] = value end
        return result
    end

    local function colorChannels(ref) return Core.colorValue(ref.channels) end

    function self.rows(model)
        if model.type == "keybind" and sessionKeys then
            local capturing = session ~= nil and session.id == model.id and session.kind == "keybind"
            local first = child(model, "value", {})
            first.id, first.parentId = model.id, nil
            first.type, first.editorAction = "action", "keybind"
            first.buttonLabel = capturing and word("pressKey") or model.displayValue
            local result = {first}
            -- Keep clearing reachable by ordinary navigation; during capture the same
            -- navigation keys are the binding itself.
            if clearable(model) then
                result[#result + 1] = child(model, "clear", {type = "action", editorAction = "clear",
                    label = word("clearBinding"), buttonLabel = word("clearBinding")})
            end
            if capturing then
                result[#result + 1] = child(model, "cancel", {type = "action", editorAction = "cancel",
                    label = word("cancel"), buttonLabel = word("cancel")})
            end
            return result
        end
        if model.type == "color" then
            local editing = session ~= nil and session.id == model.id and session.kind == "color"
            local value = editing and colorChannels(session) or model.value
            local first = child(model, "value", {})
            first.id, first.parentId = model.id, nil
            first.type, first.editorAction, first.buttonLabel, first.colorPreview = "action", "color", value, value
            local result = {first}
            if editing then
                local labels = {"red", "green", "blue", "alpha"}
                for index, channel in ipairs(session.channels) do
                    result[#result + 1] = child(model, "channel" .. (index - 1), {type = "number", editorChannel = index,
                        label = word(labels[index]), value = channel, displayValue = tostring(channel),
                        min = 0, max = 255, step = 1, minDisplayValue = "0", maxDisplayValue = "255",
                        colorPreview = nil, editorAction = nil, buttonLabel = nil})
                end
                for _, action in ipairs({"applyColor", "cancel"}) do
                    result[#result + 1] = child(model, action, {type = "action", editorAction = action,
                        label = word(action), buttonLabel = word(action), colorPreview = nil})
                end
            end
            return result
        end
        if model.type == "sound" then
            local active = playing ~= nil and playing.id == model.id
            if options.compactSound then
                local first = child(model, "value", {})
                first.id, first.parentId = model.id, nil
                first.type, first.inlineSoundPreview, first.previewPlaying = "choice", true, active
                first.previewLabel = word(active and "stop" or "preview")
                return {first}
            end
            local first = child(model, "value", {})
            first.id, first.parentId, first.type = model.id, nil, "choice"
            return {first, child(model, "preview", {type = "action", editorAction = "preview",
                label = word("preview"), buttonLabel = word(active and "stop" or "preview")})}
        end
        return {model}
    end

    local function accept(value, target)
        local s = session
        if not s then return end
        local result = host.edit(target or s, value)
        if result.ok then session, feedback = nil, nil
        else
            failure(s.id, result)
            if FATAL[result.error] then session = nil end
        end
        refresh()
    end

    function self.active() return session ~= nil or playing ~= nil end
    function self.capturing() return session ~= nil and session.kind == "keybind" end
    function self.activeId() return session and session.id end
    function self.feedback() return feedback end
    function self.colorDraft() return session and session.kind == "color" and colorChannels(session) or nil end
    function self.colorEdit()
        if not (session and session.kind == "color") then return nil end
        return {id = session.id, key = session.key, providerId = session.providerId, value = colorChannels(session),
            revision = session.revision}
    end

    function self.pickColor(value)
        if not session or session.kind ~= "color" or Core.colorError(session.control, value) then return false end
        session.channels, feedback = Core.colorChannels(value), nil
        refresh()
        return true
    end

    function self.setBrightness(value)
        if not (session and session.kind == "color" and options.palette) then return false end
        return self.pickColor(options.palette.brightness(colorChannels(session), value))
    end

    -- models: id -> current model (after the provider was re-read)
    -- Returns true when a session or preview was revoked (the caller rebuilds its rows).
    function self.reconcile(models)
        local revoked = false
        if session and not current(models[session.id], session) then
            local id = session.id
            session, feedback, revoked = nil, {id = id, code = "REVISION_CONFLICT"}, true
        end
        if playing and not current(models[playing.id], playing) then stop(); revoked = true end
        return revoked
    end

    function self.select(id)
        if session and id ~= session.id and id:sub(1, #session.id + 2) ~= session.id .. "/@" then
            session, feedback = nil, nil
            refresh()
        end
    end

    function self.action(model)
        local kind = model.editorAction
        if not kind then return false end
        if model.enabled == false then return true end
        if kind == "cancel" then cancel(); return true end
        if kind == "clear" then
            if clearable(model) then
                local ref = reference(model)
                if model.pair then
                    ref.patch = {}
                    if model.control.allowUnbound ~= false then ref.patch[model.key] = "" end
                    if model.pair.control.allowUnbound ~= false then ref.patch[model.pair.key] = "" end
                end
                local result = host.edit(ref, "")
                if result.ok then session, feedback = nil, nil else failure(model.parentId, result) end
                refresh()
            end
            return true
        end
        if kind == "applyColor" then
            if session and session.kind == "color" then accept(colorChannels(session)) end
            return true
        end
        if kind == "preview" then
            local owner = model.parentId or model.id
            if playing and playing.id == owner then stop()
            else
                local generation = stop()
                if generation ~= previewGeneration then return true end
                feedback = nil
                local result = host.preview(reference(model), options.beginAudioFocus)
                if generation ~= previewGeneration then return true end
                if result.ok then
                    playing = reference(model)
                    playing.id = owner
                    if schedule then
                        local mine = previewGeneration
                        timer = schedule(function()
                            if mine ~= previewGeneration then return end
                            stop(); refresh()
                        end, result.durationMs or 5000)
                    end
                else failure(owner, result) end
            end
            refresh()
            return true
        end
        local generation = stop()
        if generation ~= previewGeneration then return true end
        feedback = nil
        if session and session.id == model.id then session = nil; refresh(); return true end
        session = reference(model)
        session.kind = kind
        if kind == "color" then session.channels = Core.colorChannels(model.value) end
        refresh()
        return true
    end

    -- Channel number rows route here: returns true when the model belongs to an editor.
    function self.edit(model, value)
        if model.editorChannel == nil then return false end
        if session and session.kind == "color" and session.id == model.parentId and integer(value) and value >= 0
            and value <= 255 and session.channels[model.editorChannel] ~= nil then
            session.channels[model.editorChannel] = value
            feedback = nil
            refresh()
        end
        return true
    end

    function self.key(name, isRepeat, modifiers)
        if swallowed[name] and isRepeat then return true end
        if not session then return false end
        if name == "Escape" or name == "Gamepad_FaceButton_Right" then
            swallowed[name] = true
            cancel()
            return true
        end
        if session.kind ~= "keybind" then return false end
        swallowed[name] = true
        if isRepeat or Core.MODIFIER_KEYS[name] then return true end
        local gamepad = name:match("^Gamepad_") ~= nil
        local held = gamepad and {} or (modifiers or {})
        local value = Core.chord(name, held)
        local target = session
        if gamepad and session.pair then
            target = {}
            for field, item in pairs(session) do target[field] = item end
            target.key, target.control, target.pair = session.pair.key, session.pair.control, nil
        end
        local invalid = Core.bindingError(target.control, value)
        if invalid then
            feedback = {id = session.id, code = invalid}
            refresh()
            return true
        end
        accept(value, target)
        return true
    end

    function self.keyUp(name)
        local owned = swallowed[name] ~= nil
        swallowed[name] = nil
        return owned or (session ~= nil and session.kind == "keybind")
    end

    function self.close()
        session, feedback, swallowed = nil, nil, {}
        stop()
    end

    -- A world change: forget the session and any preview without asking the host to stop anything.
    function self.discardWorld()
        previewGeneration = previewGeneration + 1
        if timer ~= nil and cancelTimer then pcall(cancelTimer, timer) end
        session, feedback, swallowed, playing, timer = nil, nil, {}, nil, nil
        return true
    end

    self.cancel = cancel
    return self
end

return Editors
