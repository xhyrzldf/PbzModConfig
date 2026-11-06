-- Right-hand preview pane of the mod settings page, ported from native/NativePreview.js (0.3.13):
--   * a business appearance preview (createVisualPreview) drawn into a 1040x585 host at 0.5 scale;
--   * while a colour is being edited: original/preview swatches and, when the wheel capability is
--     available, the 180x180 colour wheel with a marker.
-- It only uses widgets it creates inside the details widget's Box_DetailsExtension.
--
-- Differences forced by UE4SS Lua (documented in the hand-off):
--   * JS binds a JS function to Border.OnMouseButtonDownEvent. Lua cannot bind a function to that
--     single-cast delegate, so a transparent native settings button (W_SettingBaseButton) lies over
--     the wheel; its OnButtonBaseClicked reads the mouse position and converts it to wheel space.
--   * A failed wheel texture import disables only the wheel (COLOR_WHEEL_FAILED); JS retired the menu.
--   * Without the wheel the swatches move to the left edge and the colour area is 100 high, not 190.
--
-- api (all injectable, production defaults from Pane.nativeApi):
--   widgets          PbzNativeWidgets-compatible {native, widget, text, valid, V}
--   events(owner, host, report) -> scope with bindClick(delegate, callback, sender) and dispose()
--   whiteTexture()   white square texture for swatches and the marker
--   importTexture(path, owner) -> texture       (wheel only)
--   mousePosition()  -> {X, Y} absolute (desktop) cursor position   (wheel only)
--   localPoint(widget, absolute) -> {X, Y} in the widget's local space (wheel only)
--   buttonClass      UClass of the transparent hit button (wheel only)
--   wheelPath        absolute path of color-wheel.png  (wheel only)
local Palette = require("PbzColorPalette")
local Core = require("PbzConfigCore")

local Pane = {WIDTH = 520, VISUAL_HEIGHT = 310, WHEEL = 180, HOST_WIDTH = 1040, HOST_HEIGHT = 585}

local WHITE_SQUARE = "/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"
local linearColor = {R = true, G = true, B = true, A = true}
local fontFields = {FontObject = true, FontMaterial = true, TypefaceFontName = true, Size = true, LetterSpacing = true,
    SkewAmount = true, bForceMonospaced = true, bMaterialIsStencil = true, MonospacedWidth = true,
    OutlineSettings = {OutlineSize = true, bMiteredCorners = true, bSeparateFillAlpha = true,
        bApplyOutlineToDropShadows = true, OutlineMaterial = true, OutlineColor = linearColor}}

-- Struct arguments must be plain tables in UE4SS (see PbzNativeWidgets).
local function plainStruct(value, fields)
    local result = {}
    for name, child in pairs(fields) do
        if type(child) == "table" then result[name] = plainStruct(value[name], child) else result[name] = value[name] end
    end
    return result
end

local function srgbToLinear(channel)
    channel = channel / 255
    if channel <= 0.04045 then return channel / 12.92 end
    return ((channel + 0.055) / 1.055) ^ 2.4
end

function Pane.linear(hex)
    local channels = Core.colorChannels(hex)
    return {R = srgbToLinear(channels[1]), G = srgbToLinear(channels[2]), B = srgbToLinear(channels[3]),
        A = (channels[4] or 255) / 255}
end

-- Production natives. The wheel entries are returned only when the caller opts in.
function Pane.nativeApi(options)
    options = options or {}
    local Widgets = require("PbzNativeWidgets")
    local function find(path)
        local object = StaticFindObject(path)
        if not Widgets.valid(object) and type(LoadAsset) == "function" then object = LoadAsset(path) end
        return object
    end
    local api = {
        widgets = Widgets,
        events = function(owner, host, report) return require("PbzNativeEvents").create(owner, host, report) end,
        whiteTexture = function()
            local texture = find(WHITE_SQUARE)
            assert(Widgets.valid(texture), "COLOR_PREVIEW_TEXTURE_MISSING")
            return texture
        end,
    }
    if options.wheel then
        api.wheelPath, api.buttonClass = options.wheelPath, options.buttonClass
        api.importTexture = function(path, owner)
            local library = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
            assert(Widgets.valid(library), "TEXTURE_LIBRARY_MISSING")
            return library:ImportFileAsTexture2D(owner, path)
        end
        api.mousePosition = function()
            local library = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
            assert(Widgets.valid(library), "WIDGET_LAYOUT_LIBRARY_MISSING")
            local position = library:GetMousePositionOnPlatform()
            return {X = position.X, Y = position.Y}
        end
        api.localPoint = function(widget, absolute)
            local library = StaticFindObject("/Script/UMG.Default__SlateBlueprintLibrary")
            assert(Widgets.valid(library), "SLATE_LIBRARY_MISSING")
            local point = library:AbsoluteToLocal(widget:GetCachedGeometry(), {X = absolute.X, Y = absolute.Y})
            return {X = point.X, Y = point.Y}
        end
    end
    return api
end

-- deps: panel (settings panel, owner of created user widgets), details (our details widget),
--       words (function(key) or table of resolved strings), report(code, detail), api (see above).
function Pane.create(deps)
    assert(type(deps) == "table" and deps.panel and deps.details, "PREVIEW_PANE_DEPS_INVALID")
    local api = deps.api or Pane.nativeApi()
    local W = assert(api.widgets, "PREVIEW_PANE_WIDGETS_MISSING")
    local V = W.V
    local panel, details = deps.panel, deps.details
    local report = deps.report or function() end
    local function log(code, detail) pcall(report, code, detail) end
    local function word(key)
        local words = deps.words
        if type(words) == "function" then return words(key) end
        if type(words) == "table" and type(words[key]) == "string" then return words[key] end
        return key
    end
    local wheelCapable = type(api.importTexture) == "function" and type(api.mousePosition) == "function"
        and type(api.localPoint) == "function" and api.buttonClass ~= nil and type(api.wheelPath) == "string"

    local self = {}
    local dead, failed = false, false
    local pane, canvas, host, caption, scope
    local slots = {}
    local swatches, labels = nil, nil
    local wheel, wheelArt, marker, wheelFailed, wheelReported = nil, nil, nil, false, false
    local opened, ownerRecord, ownerProvider, failedProvider = nil, nil, nil, nil
    local current = nil -- latest {model, ctx}, read by the wheel click

    local function alive()
        if dead then return false end
        local live = W.valid(panel) and W.valid(details)
        if live then live = W.valid(details.Box_DetailsExtension) end
        if live and pane then
            live = W.valid(pane) and W.valid(canvas) and W.valid(host) and W.valid(caption)
            for widget, slot in pairs(slots) do
                if not W.valid(widget) or not W.valid(slot) then live = false; break end
            end
        end
        if not live then
            failed = true
            log("PREVIEW_PANE_FAILED", "PREVIEW_WIDGET_DESTROYED")
            self.dispose()
            return false
        end
        return true
    end

    local function place(widget, x, y, w, h)
        local slot = canvas:AddChildToCanvas(widget)
        slot:SetPosition({X = x, Y = y})
        slot:SetSize({X = w, Y = h})
        slots[widget] = slot
        return slot
    end
    local function move(widget, x, y) slots[widget]:SetPosition({X = x, Y = y}) end

    local function label(value, x, y, w)
        local template = details.Text_SettingName
        local text = W.native(details, template:GetClass())
        local font = template.Font
        if font ~= nil then text:SetFont(plainStruct(font, fontFields)) end
        W.text(text, value)
        text:SetVisibility(V.HitTestInvisible)
        place(text, x, y, w, 28)
        return text
    end

    local function colorImage(x, y, w, h)
        local image = W.native(details, "Image")
        image:SetBrushFromTexture(api.whiteTexture(), false)
        image:SetVisibility(V.HitTestInvisible)
        place(image, x, y, w, h)
        return image
    end

    local function ensure()
        if pane then return end
        local box = details.Box_DetailsExtension
        assert(W.valid(box), "PREVIEW_EXTENSION_MISSING")
        pane = W.native(details, "SizeBox")
        pane:SetWidthOverride(Pane.WIDTH)
        pane:SetHeightOverride(300)
        box:AddChild(pane)
        canvas = W.native(details, "CanvasPanel")
        pane:SetContent(canvas)
        host = W.native(details, "Overlay")
        place(host, 0, 0, Pane.HOST_WIDTH, Pane.HOST_HEIGHT)
        host:SetRenderTransformPivot({X = 0, Y = 0})
        host:SetRenderScale({X = 0.5, Y = 0.5})
        host:SetVisibility(V.HitTestInvisible)
        caption = label("", 0, 278, 500)
    end

    local function ensureSwatches()
        if swatches then return end
        swatches = {colorImage(210, 320, 64, 48), colorImage(286, 320, 64, 48)}
        labels = {label(word("colorBefore"), 210, 290, 76), label(word("colorAfter"), 286, 290, 100)}
    end

    local function choose()
        if not alive() or not current or not wheelArt then return end
        local ok, err = pcall(function()
            local ctx = current.ctx
            if type(ctx.acceptsInput) == "function" and not ctx.acceptsInput() then return end
            local edit = ctx.colorEdit
            if not edit then return end
            local point = api.localPoint(wheelArt, api.mousePosition())
            if type(point) ~= "table" then return end
            local value = Palette.wheel(edit.value, point.X, point.Y, Pane.WHEEL)
            if value and type(ctx.pickColor) == "function" then ctx.pickColor(value) end
        end)
        if not ok then log("COLOR_PALETTE_INPUT_FAILED", tostring(err)) end
    end

    local function ensureWheel()
        if wheel or wheelFailed then return wheel ~= nil end
        if not wheelCapable then
            if not wheelReported then wheelReported = true; log("COLOR_WHEEL_UNAVAILABLE", "importTexture/mousePosition not provided") end
            wheelFailed = true
            return false
        end
        local ok, err = pcall(function()
            local texture = api.importTexture(api.wheelPath, panel)
            assert(W.valid(texture), "PALETTE_TEXTURE_UNAVAILABLE")
            local art = W.native(details, "Image")
            art:SetBrushFromTexture(texture, false)
            art:SetVisibility(V.HitTestInvisible)
            place(art, 0, 300, Pane.WHEEL, Pane.WHEEL)
            local button = W.widget(panel, api.buttonClass)
            button:SetIsInteractionEnabled(true)
            -- Mouse only, like JS: gamepad/keyboard keep editing through the channel rows.
            button:SetIsFocusable(false)
            button:SetVisibility(V.Visible)
            place(button, 0, 300, Pane.WHEEL, Pane.WHEEL)
            scope = scope or api.events(details, canvas, function(code, detail) log(code, detail) end)
            scope.bindClick(button.OnButtonBaseClicked, choose, button)
            wheelArt, wheel = art, button
            marker = colorImage(0, 300, 8, 8)
            marker:SetColorAndOpacity({R = 1, G = 1, B = 1, A = 1})
        end)
        if not ok then
            wheelFailed = true
            log("COLOR_WHEEL_FAILED", tostring(err))
            for _, widget in ipairs({wheelArt, wheel, marker}) do
                if widget then pcall(function() widget:SetVisibility(V.Collapsed) end) end
            end
            wheelArt, wheel, marker = nil, nil, nil
            return false
        end
        return true
    end

    local function release()
        local visual = current and current.ctx and current.ctx.visual
        if opened then
            opened.dispose()
        elseif visual and ownerRecord then visual.release(ownerRecord) end
        opened, ownerRecord, ownerProvider = nil, nil, nil
    end

    function self.hide()
        if not alive() then return end
        release()
        current = nil
        if pane then pane:SetVisibility(V.Collapsed) end
    end

    local function retire(err)
        failed = true
        log("PREVIEW_PANE_FAILED", tostring(err))
        self.dispose()
    end

    -- model: the selected row model (may be nil); ctx: {record, colorEdit, committed, visual, acceptsInput, pickColor}
    function self.update(model, ctx)
        if not alive() then return false end
        ctx = ctx or {}
        current = {model = model, ctx = ctx}
        local ok, err = pcall(function()
            if type(ctx.acceptsInput) == "function" and not ctx.acceptsInput() then self.hide(); return end
            local edit = ctx.colorEdit
            local record, visual = ctx.record, ctx.visual
            local key = edit and edit.key or (model and model.key)
            local showVisual = visual ~= nil and record ~= nil and model ~= nil and not model.section
                and type(key) == "string" and visual.has(record, key)
            if not edit and not showVisual then self.hide(); return end
            ensure()
            pane:SetVisibility(V.SelfHitTestInvisible)
            details.Box_DetailsExtension:SetVisibility(V.SelfHitTestInvisible)
            local colorY = showVisual and Pane.VISUAL_HEIGHT or 0
            if showVisual then
                host:SetVisibility(V.HitTestInvisible)
                if ownerRecord ~= record or ownerProvider ~= record.provider then
                    release()
                    if failedProvider ~= record.provider then
                        local result = visual.open(record, {owner = panel, host = host, width = Pane.HOST_WIDTH, height = Pane.HOST_HEIGHT,
                            setCaption = function(value) if alive() then W.text(caption, value) end end,
                            report = function(problem) log("PROVIDER_PREVIEW_FAILED", tostring(problem)) end})
                        if result.ok then opened, ownerRecord, ownerProvider = result, record, record.provider
                        else failedProvider = record.provider end
                    end
                end
                if opened and not opened.update(key, edit) then
                    release()
                    failedProvider = record.provider
                end
            else
                release()
                host:SetVisibility(V.Collapsed)
            end
            caption:SetVisibility(showVisual and V.HitTestInvisible or V.Collapsed)
            if edit then
                ensureSwatches()
                local hasWheel = ensureWheel()
                local x = hasWheel and 210 or 0
                pane:SetHeightOverride(colorY + (hasWheel and 190 or 100))
                if hasWheel then
                    wheel:SetVisibility(V.Visible); wheelArt:SetVisibility(V.HitTestInvisible); marker:SetVisibility(V.HitTestInvisible)
                    move(wheelArt, 0, colorY); move(wheel, 0, colorY)
                    local point = Palette.marker(edit.value, Pane.WHEEL)
                    move(marker, point.x - 4, point.y + colorY - 4)
                end
                for index, text in ipairs(labels) do
                    W.text(text, word(index == 1 and "colorBefore" or "colorAfter"))
                    move(text, x + (index - 1) * 76, colorY + 8)
                    text:SetVisibility(V.HitTestInvisible)
                end
                local before = ctx.committed
                if Core.colorError({alpha = #tostring(edit.value) == 9}, before) then before = edit.value end
                for index, image in ipairs(swatches) do
                    move(image, x + (index - 1) * 76, colorY + 40)
                    image:SetColorAndOpacity(Pane.linear(index == 1 and before or edit.value))
                    image:SetVisibility(V.HitTestInvisible)
                end
            else
                pane:SetHeightOverride(Pane.VISUAL_HEIGHT)
                for _, widget in ipairs({wheel, wheelArt, marker}) do if widget then widget:SetVisibility(V.Collapsed) end end
                for _, widget in ipairs(swatches or {}) do widget:SetVisibility(V.Collapsed) end
                for _, widget in ipairs(labels or {}) do widget:SetVisibility(V.Collapsed) end
            end
        end)
        if not ok then retire(err); return false end
        return true
    end

    function self.state()
        return {dead = dead, failed = failed, wheel = wheel ~= nil, wheelFailed = wheelFailed, previewOpen = opened ~= nil}
    end

    function self.dispose()
        if dead then return end
        dead = true
        local steps = {
            function() release() end,
            function() if scope then scope.dispose() end end,
            function() if pane and W.valid(pane) then pane:RemoveFromParent() end end,
        }
        for _, step in ipairs(steps) do
            local ok, err = pcall(step)
            if not ok then log("PREVIEW_PANE_DISPOSE_FAILED", tostring(err)) end
        end
        current = nil
        panel, details, pane, canvas, host, caption, scope = nil, nil, nil, nil, nil, nil, nil
        slots, swatches, labels = {}, nil, nil
        wheel, wheelArt, marker = nil, nil, nil
    end

    return self
end

return Pane
