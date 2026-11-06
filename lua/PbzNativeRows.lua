local Widgets = require("PbzNativeWidgets")
local Events = require("PbzNativeEvents")
local BindingRules = require("PbzBindingRules")
local Rows = {}

local kinds = {header = "Header", toggle = "Discrete", choice = "Discrete", number = "Scalar", action = "Discrete", keybind = "Discrete"}
local editors = "/Game/PBZContent/UI/Settings/Editors/"

local vector2 = {X = true, Y = true}
local linearColor = {R = true, G = true, B = true, A = true}
local slateColor = {SpecifiedColor = linearColor, ColorUseRule = true}
local brush = {
    TintColor = slateColor, DrawAs = true, Tiling = true, Mirroring = true, ImageType = true,
    ImageSize = vector2, Margin = {Left = true, Top = true, Right = true, Bottom = true},
    ResourceObject = true, ResourceName = true, bIsDynamicallyLoaded = true, bHasUObject = true,
    UVRegion = {min = vector2, max = vector2, bIsValid = true},
    OutlineSettings = {CornerRadii = {X = true, Y = true, Z = true, W = true}, Color = slateColor,
        Width = true, RoundingType = true, bUseBrushTransparency = true}
}
local sliderStyle = {NormalBarImage = brush, HoveredBarImage = brush, DisabledBarImage = brush,
    NormalThumbImage = brush, HoveredThumbImage = brush, DisabledThumbImage = brush, BarThickness = true}
local margin = {Left = true, Top = true, Right = true, Bottom = true}
local font = {FontObject = true, FontMaterial = true, TypefaceFontName = true, Size = true, LetterSpacing = true,
    SkewAmount = true, bForceMonospaced = true, bMaterialIsStencil = true, MonospacedWidth = true,
    OutlineSettings = {OutlineSize = true, bMiteredCorners = true, bSeparateFillAlpha = true,
        bApplyOutlineToDropShadows = true, OutlineMaterial = true, OutlineColor = linearColor}}
local buttonStyle = {Normal = brush, Hovered = brush, Pressed = brush, Disabled = brush,
    NormalForeground = slateColor, HoveredForeground = slateColor, PressedForeground = slateColor, DisabledForeground = slateColor,
    NormalPadding = margin, PressedPadding = margin, PressedSlateSound = {ResourceObject = true},
    ClickedSlateSound = {ResourceObject = true}, HoveredSlateSound = {ResourceObject = true}}
local textStyle = {Font = font, ColorAndOpacity = slateColor, ShadowOffset = vector2,
    ShadowColorAndOpacity = linearColor, SelectedBackgroundColor = slateColor, HighlightColor = slateColor,
    HighlightShape = brush, StrikeBrush = brush, UnderlineBrush = brush, TransformPolicy = true, OverflowPolicy = true}

local WHITE_SQUARE = "/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"
-- Build 26266538 Audio-tab speaker brush (same asset the JS 0.3.8 preview row draws).
local SPEAKER = "/Game/PBZContent/UI/Settings/Texture/T_SecondTab_Settings_ShengYin.T_SecondTab_Settings_ShengYin"

local function asset(path, code)
    local object = StaticFindObject(path)
    if not Widgets.valid(object) then object = LoadAsset(path) end
    assert(Widgets.valid(object), code)
    return object
end

local function srgbToLinear(channel)
    channel = channel / 255
    if channel <= 0.04045 then return channel / 12.92 end
    return ((channel + 0.055) / 1.055) ^ 2.4
end

-- "#RRGGBB[AA]" -> LinearColor table; nil when the text is not a colour.
local function tintOf(value)
    if type(value) ~= "string" or (#value ~= 7 and #value ~= 9) or not value:match("^#%x+$") then return nil end
    local function byte(index) return tonumber(value:sub(index, index + 1), 16) end
    return {R = srgbToLinear(byte(2)), G = srgbToLinear(byte(4)), B = srgbToLinear(byte(6)), A = #value == 9 and byte(8) / 255 or 1}
end

local function report(code, detail)
    print("[PbzModConfig] " .. code .. " " .. tostring(detail) .. "\n")
end

local function hasMethod(object, name)
    local method = object[name]
    return type(method) == "function" or (type(method) == "userdata" and method:IsValid())
end

local function plainStruct(value, fields)
    local result = {}
    for name, child in pairs(fields) do
        if type(child) == "table" then result[name] = plainStruct(value[name], child)
        else result[name] = value[name] end
    end
    return result
end

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function options(model)
    if model.options then return model.options end
    if model.type == "toggle" then
        return {{value = false, label = model.offLabel or "关闭"}, {value = true, label = model.onLabel or "开启"}}
    end
    return {}
end

local function bindingSpec(model)
    return model.control or model
end

local function validate(model, expectedType)
    local typeName = type(model) == "table" and model.type or nil
    assert(typeName and kinds[typeName], "UNSUPPORTED_ROW_TYPE " .. tostring(typeName))
    assert(not expectedType or model.type == expectedType, "ROW_TYPE_CHANGED")
    if model.type == "choice" or model.type == "toggle" then
        assert(#options(model) > 0, "ROW_OPTIONS_REQUIRED")
        for _, option in ipairs(options(model)) do assert(option.value ~= nil, "ROW_OPTION_VALUE_MISSING") end
    elseif model.type == "number" then
        assert(finite(model.min) and finite(model.max) and finite(model.step) and finite(model.value), "ROW_NUMBER_INVALID")
        assert(model.min < model.max and model.step > 0, "ROW_NUMBER_RANGE_INVALID")
        local steps = (model.max - model.min) / model.step
        assert(steps <= 1e9 and math.abs(steps - math.floor(steps + 0.5)) <= 1e-7, "ROW_NUMBER_STEP_INVALID")
    elseif model.type == "keybind" then
        assert(not BindingRules.bindingError(bindingSpec(model), model.value), "ROW_BINDING_INVALID")
    end
end

local function inputChord(value)
    local key, held = BindingRules.parse(value)
    return {Key = {KeyName = FName(key == "" and "None" or key)}, bShift = held.Shift == true,
        bCtrl = held.Ctrl == true, bAlt = held.Alt == true, bCmd = held.Cmd == true}
end

local function optionIndex(model)
    for index, option in ipairs(options(model)) do
        if option.value == model.value then return index end
    end
    return 1
end

local function roundedNumber(model, position)
    local steps = math.floor((model.max - model.min) / model.step + 0.5)
    local tick = math.floor(math.max(0, math.min(1, position)) * steps + 0.5)
    return tonumber(string.format("%.10f", model.min + tick * model.step))
end

local function copySliderStyle(old, fresh)
    -- Every nested struct is a table. UObject/FName leaves keep their native wrappers.
    fresh.WidgetStyle = plainStruct(old.WidgetStyle, sliderStyle)
    for _, name in ipairs({"Textstyle", "TextStyleCJK", "BarMaterial"}) do
        if Widgets.valid(old[name]) then fresh[name] = old[name] end
    end
    for _, name in ipairs({"FilledBarTint", "UnfilledBarTint"}) do
        if Widgets.valid(old[name]) then fresh[name] = plainStruct(old[name], linearColor) end
    end
    for _, name in ipairs({"Orientation", "IndentHandle", "MouseUsesStep", "RequiresControllerLock"}) do
        local value = old[name]
        if type(value) == "number" or type(value) == "boolean" then fresh[name] = value end
    end
end

function Rows.create(owner, host, model, onChange, extras)
    extras = extras or {}
    validate(model)
    assert(model.type == "header" or type(onChange) == "function", "ROW_CHANGE_HANDLER_MISSING")
    local initialType = model.type
    local current, active, applying = model, true, true
    local row, scope, applyValue, refreshSelected, primary
    local controls, owned = {}, {}
    -- Every child widget a later update calls; all are checked first, since a live row does not prove
    -- its children are (review 2026-11-05). A row that lost one fails instead of calling it.
    local parts = {}
    local function keep(...) for _, widget in ipairs({...}) do parts[#parts + 1] = widget end end
    local lost
    local function intact()
        if not Widgets.valid(row) then return false end
        for _, widget in ipairs(controls) do if not Widgets.valid(widget) then return false end end
        for _, widget in ipairs(parts) do if not Widgets.valid(widget) then return false end end
        return true
    end
    local result = {}
    local selected = false

    -- Selection is view state owned by the menu (JS NativeMenu.select); a model may still carry
    -- `selected` for callers that render a fixed selection.
    local function isSelected(value) return selected or value.selected == true end

    local function editable()
        return active and not applying and current.enabled ~= false
    end

    -- source: nil for discrete input, "drag" for slider samples (saved on capture end, B09).
    local function changed(value, source)
        if editable() and value ~= current.value then onChange(value, source) end
    end

    local function delegateLike(value)
        return type(value) == "userdata" or (type(value) == "table" and type(value.Add) == "function")
    end

    -- Hook for the option font (JS createChoiceTypography); never allowed to break the row.
    local function styleChoice(control, label)
        if type(extras.styleChoice) ~= "function" then return end
        local ok, err = pcall(extras.styleChoice, control, label, current.locale)
        if not ok then report("CHOICE_FONT_FAILED", err) end
    end

    local function cycle(delta)
        local values = options(current)
        local index = (optionIndex(current) - 1 + delta) % #values + 1
        changed(values[index].value)
    end

    local function step(delta)
        changed(roundedNumber(current, (current.value + delta * current.step - current.min) / (current.max - current.min)))
    end

    -- True once the row's events and widgets are released; a failed step is retried by a later
    -- call (the row is inert from the first call on).
    local released, rowRemoved = false, false
    -- A world change took the page: the row goes inert and its event routes are dropped in Lua only;
    -- none of its widgets or delegates is touched (they belong to the old world).
    function result.discardWorld()
        active, released, rowRemoved, owned = false, true, true, {}
        result.row, result.keySelector, primary = nil, nil, nil
        if scope and type(scope.discardWorld) == "function" then pcall(scope.discardWorld) end
        scope = nil
        return true
    end
    -- A child widget died: the row is forgotten the same way before the failure is raised, so the page's
    -- later release never reaches its delegates or widgets (review 2026-11-05, round 4).
    lost = function()
        result.discardWorld()
        error("ROW_WIDGET_LOST", 0)
    end
    function result.dispose()
        if released then return true end
        -- A row that lost a widget is forgotten, never released piecemeal (review round 8).
        if not intact() then return result.discardWorld() end
        active = false
        local clean = true
        if scope then
            local ok, cleared = pcall(scope.dispose)
            if not ok then
                report("ROW_EVENT_RELEASE_FAILED", cleared)
                clean = false
            elseif cleared == false then clean = false end
        end
        local left = {}
        for index = #owned, 1, -1 do
            local extra = owned[index]
            local removed, failure = pcall(function() if Widgets.valid(extra) then extra:RemoveFromParent() end end)
            if not removed then
                report("ROW_RELEASE_FAILED", failure)
                clean = false
                left[#left + 1] = extra
            end
        end
        owned = {}
        for index = #left, 1, -1 do owned[#owned + 1] = left[index] end
        if not rowRemoved then
            local ok, err = pcall(function()
                if Widgets.valid(row) then row:RemoveFromParent() end
            end)
            if ok then rowRemoved = true
            else
                report("ROW_RELEASE_FAILED", err)
                clean = false
            end
        end
        released = clean
        return clean
    end

    function result.setSelected(flag)
        if not active then return end
        flag = flag == true
        if flag == selected then return end
        if not intact() then lost() end
        selected = flag
        local ok, err = pcall(function()
            if hasMethod(row, "SetSelected") then row:SetSelected(isSelected(current)) end
            if refreshSelected then refreshSelected(current) end
        end)
        if not ok then error(err, 0) end
    end

    -- JS focusReady: an editable row focuses its control, a disabled one the row itself.
    function result.focus()
        if not active then return false end
        if not intact() then lost() end
        local target = current.enabled ~= false and primary or row
        if target and Widgets.valid(target) and hasMethod(target, "SetFocus") then target:SetFocus(); return true end
        if Widgets.valid(row) and hasMethod(row, "SetFocus") then row:SetFocus(); return true end
        return false
    end

    function result.model() return current end

    function result.update(nextModel)
        if not active then return end
        validate(nextModel, initialType)
        if not intact() then lost() end
        current, applying = nextModel, true
        local ok, err = pcall(function()
            Widgets.text(row.Text_SettingName, current.label)
            if current.type == "header" or current.section then
                row.Text_SettingName:SetJustification(0)
                local slot = row.Text_SettingName.Slot
                if Widgets.valid(slot) and hasMethod(slot, "SetHorizontalAlignment") then slot:SetHorizontalAlignment(0) end
            end
            if hasMethod(row, "SetSelected") then row:SetSelected(isSelected(current)) end
            applyValue(current)
            for _, control in ipairs(controls) do control:SetIsEnabled(current.enabled ~= false) end
            -- A disabled control keeps the native disabled look but cannot take focus. Let the row
            -- itself take it instead, so its reason stays reachable (JS focuses the row host then).
            if initialType ~= "header" and hasMethod(row, "SetIsFocusable") then row:SetIsFocusable(current.enabled == false) end
        end)
        applying = false
        if not ok then error(err, 0) end
    end

    local ok, err = pcall(function()
        local name = "W_SettingsListEntry_" .. kinds[initialType]
        local path = editors .. name .. "." .. name .. "_C"
        local class = StaticFindObject(path)
        if not Widgets.valid(class) then class = LoadAsset(path) end
        assert(Widgets.valid(class), "ROW_ASSET_MISSING " .. name)
        row = Widgets.widget(owner, class)
        result.row = row
        assert(Widgets.valid(row.Text_SettingName), "ROW_LABEL_MISSING")
        keep(row.Text_SettingName)
        if initialType ~= "number" then row.TickFrequency = 0 end
        row:SetVisibility(Widgets.V.SelfHitTestInvisible)
        local root = host
        if Widgets.is(host, "UserWidget") then root = host.WidgetTree.RootWidget end
        assert(Widgets.valid(root), "ROW_HOST_MISSING")
        if model.colorPreview ~= nil or model.inlineSoundPreview then
            -- Overlays (colour swatch, speaker) must sit on top of this row, not become
            -- extra scroll entries: wrap the row in its own Overlay, as the JS entry root does.
            local holder = Widgets.native(owner, "Overlay")
            owned[#owned + 1] = holder
            result.outer = holder
            local holderSlot = root:AddChild(holder)
            if hasMethod(holderSlot, "SetHorizontalAlignment") then holderSlot:SetHorizontalAlignment(0) end
            if hasMethod(holderSlot, "SetVerticalAlignment") then holderSlot:SetVerticalAlignment(0) end
            root = holder
        end
        local slot = root:AddChild(row)
        result.outer = result.outer or row
        if hasMethod(slot, "SetHorizontalAlignment") then slot:SetHorizontalAlignment(0) end
        if hasMethod(slot, "SetVerticalAlignment") then slot:SetVerticalAlignment(0) end
        -- The native row root can be a UserWidget. Keep hidden receivers in
        -- the verified parent panel, which also retains them for this row.
        -- A widget of the row found dead: the row is forgotten and its owner (the page) told, so nobody
        -- outside keeps calling the row either (review 2026-11-05, round 9).
        scope = Events.create(row, root, report, extras.fault, function()
            result.discardWorld()
            if type(extras.lost) == "function" then extras.lost() end
        end)

        local function button(old, callback)
            assert(Widgets.valid(old), "ROW_BUTTON_MISSING")
            local fresh = Widgets.widget(owner, old:GetClass())
            Widgets.replaceControl(row, old, fresh)
            fresh:SetIsInteractionEnabled(true)
            fresh:SetIsFocusable(true)
            controls[#controls + 1] = fresh
            if not result.buttonClass then result.buttonClass = old:GetClass() end
            scope.bindClick(fresh.OnButtonBaseClicked, function()
                if editable() then callback() end
            end, fresh)
            return fresh
        end

        local function populate(control, values, index)
            local labels = {}
            for _, option in ipairs(values) do labels[#labels + 1] = Widgets.asText(option.label) end
            control:PopulateTextLabels(labels)
            control:SetSelectedItem(index - 1)
        end

        if initialType == "toggle" or initialType == "choice" then
            local old = row.Rotator_SettingValue
            assert(Widgets.valid(old), "ROW_ROTATOR_MISSING")
            local fresh = Widgets.widget(owner, old:GetClass())
            Widgets.replaceControl(row, old, fresh)
            row.Rotator_SettingValue = fresh
            fresh:SetIsInteractionEnabled(true)
            fresh:SetIsFocusable(true)
            controls[#controls + 1] = fresh
            scope.bindClick(fresh.OnRotated, function()
                if not editable() then return end
                local option = options(current)[fresh:GetSelectedIndex() + 1]
                if option then changed(option.value) end
            end, fresh)
            scope.bindClick(fresh.OnButtonBaseClicked, function() if editable() then cycle(1) end end, fresh)
            row.Button_Decrease = button(row.Button_Decrease, function() cycle(-1) end)
            row.Button_Increase = button(row.Button_Increase, function() cycle(1) end)
            primary = fresh
            applyValue = function(value)
                populate(fresh, options(value), optionIndex(value))
                local option = options(value)[optionIndex(value)]
                styleChoice(fresh, option and option.label)
            end
            if model.inlineSoundPreview then
                -- The native settings button has an empty Overlay. Keep its hit target and draw
                -- the game's own Audio-tab speaker brush above it (JS 0.3.8 layout).
                assert(type(extras.preview) == "function", "ROW_PREVIEW_HANDLER_MISSING")
                local preview = Widgets.widget(owner, row.Button_Increase:GetClass())
                preview:SetIsInteractionEnabled(true)
                preview:SetIsFocusable(false)
                preview:SetVisibility(Widgets.V.Visible)
                controls[#controls + 1] = preview
                owned[#owned + 1] = preview
                -- Row hosts can have OverlaySlot/BoxSlot roots; only our own CanvasPanel
                -- promises the anchor/position API used below.
                local layer = Widgets.native(row, "CanvasPanel")
                layer:SetVisibility(Widgets.V.SelfHitTestInvisible)
                owned[#owned + 1] = layer
                local layerSlot = root:AddChild(layer)
                if hasMethod(layerSlot, "SetHorizontalAlignment") then layerSlot:SetHorizontalAlignment(0) end
                if hasMethod(layerSlot, "SetVerticalAlignment") then layerSlot:SetVerticalAlignment(0) end
                local function place(widget, width, height, right)
                    local canvasSlot = layer:AddChildToCanvas(widget)
                    canvasSlot:SetAnchors({Minimum = {X = 1, Y = 0.5}, Maximum = {X = 1, Y = 0.5}})
                    canvasSlot:SetAlignment({X = 1, Y = 0.5})
                    canvasSlot:SetPosition({X = -right, Y = 0})
                    canvasSlot:SetSize({X = width, Y = height})
                end
                place(preview, 76, 60, 22)
                local icon = Widgets.native(row, "Image")
                keep(icon)
                owned[#owned + 1] = icon
                icon:SetBrushFromTexture(asset(SPEAKER, "PREVIEW_SPEAKER_ASSET_MISSING"), false)
                icon:SetVisibility(Widgets.V.HitTestInvisible)
                place(icon, 42, 42, 39)
                -- Build 26266538: Button_Decrease/Increase are CHILDREN of their Overlays.
                -- Translating both moves the hit box twice.
                for _, widget in ipairs({fresh, row.DecreaseOverlay, row.IncreaseOverlay}) do
                    widget:SetRenderTranslation({X = -120, Y = 0})
                end
                scope.bindClick(preview.OnButtonBaseClicked, function() if editable() then extras.preview() end end, preview)
                local choose = applyValue
                local function ink(value)
                    local level = isSelected(value) and 0.08 or 1
                    icon:SetColorAndOpacity({R = level, G = level, B = level, A = value.previewPlaying and 1 or 0.68})
                    icon:SetRenderOpacity(value.enabled == false and 0.4 or 1)
                end
                applyValue = function(value)
                    choose(value)
                    ink(value)
                end
                refreshSelected = ink
                result.previewControl, result.previewIcon = preview, icon
            end
        elseif initialType == "number" then
            local old = row.Slider_SettingValue
            assert(Widgets.valid(old), "ROW_SLIDER_MISSING")
            local fresh = Widgets.native(row, old:GetClass())
            copySliderStyle(old, fresh)
            Widgets.replaceControl(row, old, fresh)
            row.Slider_SettingValue = fresh
            fresh:SetMinValue(0)
            fresh:SetMaxValue(1)
            controls[#controls + 1] = fresh
            scope.bindNumber(fresh.OnValueChanged, function(value)
                if editable() and finite(value) then changed(roundedNumber(current, value), "drag") end
            end, fresh)
            primary = fresh
            -- B09: dragging only applies; releasing the slider saves (JS OnMouse/ControllerCaptureEnd).
            if type(extras.commit) == "function" then
                for _, name in ipairs({"OnMouseCaptureEnd", "OnControllerCaptureEnd"}) do
                    local event = fresh[name]
                    if delegateLike(event) then
                        scope.bindClick(event, function() if active and not applying then extras.commit() end end, fresh)
                    end
                end
            end
            row.Button_Decrease = button(row.Button_Decrease, function() step(-1) end)
            row.Button_Increase = button(row.Button_Increase, function() step(1) end)
            row:InitCachedTexts()
            local fixed, cursor = row.CurrentValue, row.Text_SettingValue
            local left = Widgets.valid(row.Text_LeftValue) and row.Text_LeftValue or row.LeftValue
            local right = Widgets.valid(row.Text_RightValue) and row.Text_RightValue or row.RightValue
            assert(Widgets.valid(fixed) and Widgets.valid(cursor) and Widgets.valid(left) and Widgets.valid(right), "SCALAR_VALUE_LAYOUT_UNAVAILABLE")
            keep(fixed, cursor, left, right)
            applyValue = function(value)
                fresh:SetStepSize(value.step / (value.max - value.min))
                fresh:SetValue(math.max(0, math.min(1, (value.value - value.min) / (value.max - value.min))))
                Widgets.text(fixed, value.displayValue or value.value)
                Widgets.text(cursor, value.displayValue or value.value)
                Widgets.text(left, value.minDisplayValue or value.min)
                Widgets.text(right, value.maxDisplayValue or value.max)
                fixed:SetRenderOpacity(1)
                cursor:SetRenderOpacity(1)
                refreshSelected(value)
            end
            -- Build 26266538 native Scalar: browse = fixed current value; selected = both range
            -- endpoints plus the thumb-following value (B07). The maximum is never replaced.
            refreshSelected = function(value)
                local on = isSelected(value)
                fixed:SetVisibility(on and Widgets.V.Hidden or Widgets.V.SelfHitTestInvisible)
                for _, label in ipairs({left, right, cursor}) do
                    label:SetVisibility(on and Widgets.V.SelfHitTestInvisible or Widgets.V.Hidden)
                end
                row:UpdateCursorTextPosition()
            end
        elseif initialType == "keybind" then
            local old = row.Rotator_SettingValue
            assert(Widgets.valid(old), "ROW_ROTATOR_MISSING")
            local label = Widgets.valid(old.Text) and old.Text or old.MyText
            assert(Widgets.valid(label), "KEYBIND_FONT_SOURCE_MISSING")
            local nativeButtonStyle = plainStruct(old.NormalStyle, buttonStyle)
            local nativeFont = plainStruct(label.Font, font)
            local nativeColor = plainStruct(label.ColorAndOpacity, slateColor)
            local selector = Widgets.native(row, "InputKeySelector")
            selector.WidgetStyle = nativeButtonStyle
            local textField = Widgets.valid(selector.TextStyle) and "TextStyle" or "Textstyle"
            assert(Widgets.valid(selector[textField]), "KEYBIND_TEXT_STYLE_MISSING")
            local nativeTextStyle = plainStruct(selector[textField], textStyle)
            nativeTextStyle.Font = nativeFont
            nativeTextStyle.ColorAndOpacity = nativeColor
            selector[textField] = nativeTextStyle
            selector.Margin = plainStruct(old.NormalStyle.NormalPadding, margin)
            Widgets.replaceControl(row, old, selector)
            old:RemoveFromParent()
            -- Rotator_SettingValue is typed as CommonRotator. Keep its detached
            -- original there instead of storing an incompatible InputKeySelector.
            result.keySelector = selector
            controls[#controls + 1] = selector
            primary = selector
            selector:SetTextBlockVisibility(Widgets.V.HitTestInvisible)
            selector:SetEscapeKeys({{KeyName = FName("Escape")}, {KeyName = FName("Gamepad_FaceButton_Right")}})

            local function restoreBinding()
                local wasApplying = applying
                applying = true
                local restored, failure = pcall(function() selector:SetSelectedKey(inputChord(current.value)) end)
                applying = wasApplying
                if not restored then error(failure, 0) end
            end
            scope.bindKey(selector.OnKeySelected, function(selected)
                if not editable() then return end
                local key = selected.Key.KeyName:ToString()
                if key == "Escape" or key == "Gamepad_FaceButton_Right" then
                    restoreBinding()
                    result.bindingError = nil
                    return
                end
                local value = BindingRules.chord(key, {Ctrl = selected.bCtrl, Alt = selected.bAlt,
                    Shift = selected.bShift, Cmd = selected.bCmd})
                local failure = BindingRules.bindingError(bindingSpec(current), value)
                if key == "None" then failure = "INVALID_KEY" end
                if failure then
                    restoreBinding()
                    result.bindingError = failure
                    report("KEYBIND_REJECTED", failure)
                    return
                end
                result.bindingError = nil
                changed(value)
            end, selector)

            local clear = Widgets.native(row, "Button")
            clear.WidgetStyle = plainStruct(old.NormalStyle, buttonStyle)
            local clearLabel = Widgets.native(row, "TextBlock")
            keep(selector, clear, clearLabel)
            clearLabel:SetFont(nativeFont)
            clearLabel:SetColorAndOpacity(nativeColor)
            clearLabel:SetJustification(1)
            clearLabel:SetVisibility(Widgets.V.HitTestInvisible)
            clear:SetContent(clearLabel)
            Widgets.replaceControl(row, row.Button_Increase, clear)
            result.clearButton = clear
            row.Button_Decrease:SetVisibility(Widgets.V.Collapsed)
            row.DecreaseOverlay:RemoveFromParent()
            local increase = clear:GetParent()
            assert(increase:GetAddress() == row.IncreaseOverlay:GetAddress(), "KEYBIND_CLEAR_LAYOUT_UNSUPPORTED")
            for index = 0, increase:GetChildrenCount() - 1 do
                local child = increase:GetChildAt(index)
                if child:GetAddress() ~= clear:GetAddress() then child:SetVisibility(Widgets.V.Collapsed) end
            end
            scope.bindClick(clear.OnClicked, function()
                if editable() and bindingSpec(current).allowUnbound ~= false then
                    result.bindingError = nil
                    changed("")
                end
            end, clear)
            applyValue = function(value)
                local spec = bindingSpec(value)
                selector:SetAllowGamepadKeys(spec.allowGamepad ~= false)
                selector:SetAllowModifierKeys(spec.allowModifiers ~= false)
                selector:SetKeySelectionText(Widgets.asText(value.captureLabel or "按下按键"))
                selector:SetNoKeySpecifiedText(Widgets.asText(value.unboundLabel or "未设置"))
                selector:SetSelectedKey(inputChord(value.value))
                Widgets.text(clearLabel, value.clearLabel or "清除")
                local allowClear = spec.allowUnbound ~= false
                clear:SetVisibility(allowClear and Widgets.V.Visible or Widgets.V.Collapsed)
                clear:SetIsEnabled(allowClear and value.enabled ~= false)
                result.bindingError = nil
            end
        elseif initialType == "action" then
            local fresh = button(row.Rotator_SettingValue, function() onChange() end)
            row.Rotator_SettingValue = fresh
            primary = fresh
            row.Button_Decrease:SetVisibility(Widgets.V.Collapsed)
            row.Button_Increase:SetVisibility(Widgets.V.Collapsed)
            row.DecreaseOverlay:RemoveFromParent()
            row.IncreaseOverlay:RemoveFromParent()
            fresh.OptionsScalingSizeBox:RemoveFromParent()
            if model.section and model.expandLabel and model.collapseLabel then
                -- A mod title holds two native labels: index 0 = collapsed ("Expand"), 1 = expanded
                -- ("Collapse"). Left/right rotate natively and request that state (JS: left collapses,
                -- right expands; a two-item rotator wraps, so either direction toggles here).
                scope.bindClick(fresh.OnRotated, function()
                    if not editable() then return end
                    local wanted = fresh:GetSelectedIndex() == 1
                    if wanted ~= (current.expanded == true) then onChange(wanted) end
                end, fresh)
                applyValue = function(value)
                    populate(fresh, {{label = value.expandLabel}, {label = value.collapseLabel}}, value.expanded and 2 or 1)
                    styleChoice(fresh, value.expanded and value.collapseLabel or value.expandLabel)
                end
            else
                applyValue = function(value)
                    populate(fresh, {{label = value.buttonLabel or value.label}}, 1)
                    styleChoice(fresh, value.buttonLabel or value.label)
                end
            end
        else
            applyValue = function() end
        end
        if model.colorPreview ~= nil then
            assert(initialType == "action", "COLOR_PREVIEW_ROW_TYPE")
            local swatch = Widgets.native(row, "Image")
            owned[#owned + 1] = swatch
            keep(swatch)
            swatch:SetBrushFromTexture(asset(WHITE_SQUARE, "COLOR_PREVIEW_TEXTURE_MISSING"), false)
            swatch:SetVisibility(Widgets.V.HitTestInvisible)
            local swatchSlot = root:AddChild(swatch)
            if hasMethod(swatchSlot, "SetAnchors") then
                swatchSlot:SetAnchors({Minimum = {X = 1, Y = 0.5}, Maximum = {X = 1, Y = 0.5}})
                swatchSlot:SetAlignment({X = 1, Y = 0.5})
                swatchSlot:SetPosition({X = -220, Y = 0})
                swatchSlot:SetSize({X = 28, Y = 28})
            else
                if hasMethod(swatch, "SetDesiredSizeOverride") then swatch:SetDesiredSizeOverride({X = 28, Y = 28}) end
                if hasMethod(swatchSlot, "SetHorizontalAlignment") then swatchSlot:SetHorizontalAlignment(3) end
                if hasMethod(swatchSlot, "SetVerticalAlignment") then swatchSlot:SetVerticalAlignment(2) end
                if hasMethod(swatchSlot, "SetPadding") then swatchSlot:SetPadding({Left = 0, Top = 0, Right = 220, Bottom = 0}) end
            end
            result.swatch = swatch
            local previous = applyValue
            applyValue = function(value)
                previous(value)
                local tint = tintOf(value.colorPreview)
                assert(tint, "COLOR_PREVIEW_INVALID")
                swatch:SetColorAndOpacity(tint)
            end
        end
        result.update(model)
    end)
    if not ok then
        result.dispose()
        error(err, 0)
    end
    return result
end

return Rows
