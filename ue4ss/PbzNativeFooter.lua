-- Framework credit under the details pane (JS 0.3.13 native/NativeFooter.js). Only a selected mod
-- title shows it: "PbzModConfig  <version>" and the author line, at 0.6 opacity.
--
-- JS wraps the native rich text in its own Border and binds the Border's mouse delegate. Lua cannot
-- bind a function to that delegate, so the optional link (capability authorLink) lays a transparent
-- native settings button over the text and routes its OnButtonBaseClicked, the delegate route the
-- settings rows already use in the game. Everything else works without the link.
local Widgets = require("PbzNativeWidgets")
local Footer = {}

local CLICK_INTERVAL = 0.75

-- deps: details (our cloned Details_Settings), word(key), metadata {version, author, authorUrl},
--       report(code, detail), accepts() -> bool, now() -> seconds,
--       link = {buttonClass, bindClick(delegate, fn, sender), launch(url)} or nil
function Footer.create(deps)
    local view = deps.details
    local text, box = view.RichText_DynamicDetails, view.Box_DetailsExtension
    if not Widgets.valid(text) or not Widgets.valid(box) then
        deps.report("NATIVE_FOOTER_MISSING", "RichText_DynamicDetails/Box_DetailsExtension")
        return nil
    end
    local now = deps.now or os.clock
    local holder = Widgets.native(view, "Overlay")
    local ok, err = pcall(function()
        local originalSlot = text.Slot
        local slot = box:AddChild(holder)
        if Widgets.valid(originalSlot) then
            local copied, failure = pcall(Widgets.copySlot, originalSlot, slot)
            if not copied then deps.report("FOOTER_SLOT_COPY_FAILED", failure) end
        end
        text:RemoveFromParent()
        holder:AddChild(text)
        holder:SetRenderOpacity(0.6)
        text:SetVisibility(Widgets.V.Collapsed)
        box:SetVisibility(Widgets.V.Collapsed)
    end)
    if not ok then
        pcall(function() holder:RemoveFromParent() end)
        error(err, 0)
    end

    local shown, lastOpen, button = false, -math.huge, nil
    local footer = {}
    local function alive()
        if Widgets.valid(text) and Widgets.valid(box) and Widgets.valid(holder)
            and (button == nil or Widgets.valid(button)) then return true end
        shown, text, box, holder, button = false, nil, nil, nil, nil
        return false
    end
    if deps.link then
        local linked, failure = pcall(function()
            assert(deps.link.buttonClass, "AUTHOR_LINK_BUTTON_CLASS_MISSING")
            button = Widgets.widget(view, deps.link.buttonClass)
            button:SetIsFocusable(false)
            local slot = holder:AddChild(button)
            -- Fill the text area; an Overlay slot that refuses alignment still leaves a usable button.
            if slot then pcall(function() slot:SetHorizontalAlignment(0); slot:SetVerticalAlignment(0) end) end
            button:SetVisibility(Widgets.V.Collapsed)
            deps.link.bindClick(button.OnButtonBaseClicked, function()
                if not alive() or not shown or (deps.accepts and not deps.accepts()) then return end
                local t = now()
                if t - lastOpen <= CLICK_INTERVAL then return end
                lastOpen = t
                local opened, launchError = pcall(deps.link.launch, deps.metadata.authorUrl)
                if not opened then deps.report("AUTHOR_LINK_FAILED", launchError) end
            end, button)
        end)
        if not linked then
            deps.report("AUTHOR_LINK_UNAVAILABLE", failure)
            if button then pcall(function() button:RemoveFromParent() end) end
            button = nil
        end
    end

    function footer.update(visible)
        if not alive() then return false end
        shown = visible == true
        if shown then
            Widgets.text(text, "PbzModConfig  " .. deps.metadata.version .. "\n" .. deps.word("author") .. deps.metadata.author)
        end
        local visibility = shown and Widgets.V.SelfHitTestInvisible or Widgets.V.Collapsed
        text:SetVisibility(visibility)
        box:SetVisibility(visibility)
        if button then button:SetVisibility(shown and Widgets.V.Visible or Widgets.V.Collapsed) end
    end
    function footer.linked() return alive() and button ~= nil end
    function footer.box() if alive() then return box end end
    return footer
end

return Footer
