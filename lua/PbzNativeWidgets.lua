local Widgets = {}

Widgets.V = {Visible = 0, Collapsed = 1, Hidden = 2, HitTestInvisible = 3, SelfHitTestInvisible = 4}

function Widgets.valid(object)
    return object ~= nil and object:IsValid()
end

local function hasMethod(object, name)
    local method = object[name]
    return type(method) == "function" or (type(method) == "userdata" and method:IsValid())
end

function Widgets.is(object, className)
    if not Widgets.valid(object) then return false end
    local class = StaticFindObject("/Script/UMG." .. className)
    return Widgets.valid(class) and object:IsA(class)
end

local function sameObject(left, right)
    return Widgets.valid(left) and Widgets.valid(right) and left:GetAddress() == right:GetAddress()
end

function Widgets.native(owner, class)
    if type(class) == "string" then
        local name = class
        class = StaticFindObject("/Script/UMG." .. name)
        if not Widgets.valid(class) then class = StaticFindObject("/Script/CommonUI." .. name) end
    end
    assert(Widgets.valid(class), "NATIVE_CLASS_MISSING")
    assert(Widgets.valid(owner.WidgetTree), "WIDGET_TREE_MISSING")
    local result = StaticConstructObject(class, owner.WidgetTree, 0, 0x40)
    assert(Widgets.valid(result), "NATIVE_CREATE_FAILED")
    return result
end

function Widgets.widget(owner, class)
    local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    assert(Widgets.valid(library), "WIDGET_LIBRARY_MISSING")
    assert(Widgets.valid(class), "WIDGET_CLASS_MISSING")
    local result = library:Create(owner, class, owner:GetOwningPlayer())
    assert(Widgets.valid(result), "WIDGET_CREATE_FAILED")
    return result
end

function Widgets.asText(value)
    local library = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    assert(Widgets.valid(library), "TEXT_LIBRARY_MISSING")
    return library:Conv_StringToText(value == nil and "" or tostring(value))
end

function Widgets.text(label, value)
    if not Widgets.valid(label) then return end
    local text = Widgets.asText(value)
    if hasMethod(label, "SetPBZFormatText") then label:SetPBZFormatText(text)
    else label:SetText(text) end
end

-- UE4SS 1195 cannot safely marshal a UScriptStruct userdata as a struct argument.
-- Materialize every nested member before passing it to a reflected setter.
local function margin(value)
    return {Left = value.Left, Top = value.Top, Right = value.Right, Bottom = value.Bottom}
end

local function vector(value)
    return {X = value.X, Y = value.Y}
end

function Widgets.copySlot(from, to)
    assert(Widgets.valid(from) and Widgets.valid(to), "LAYOUT_SLOT_MISSING")
    if Widgets.is(from, "CanvasPanelSlot") then
        local anchors = from:GetAnchors()
        to:SetAnchors({Minimum = vector(anchors.Minimum), Maximum = vector(anchors.Maximum)})
        to:SetAlignment(vector(from:GetAlignment()))
        to:SetOffsets(margin(from:GetOffsets()))
        to:SetAutoSize(from:GetAutoSize())
        to:SetZOrder(from:GetZOrder())
    else
        if hasMethod(to, "SetPadding") then to:SetPadding(margin(from.Padding)) end
        if hasMethod(to, "SetHorizontalAlignment") then to:SetHorizontalAlignment(from.HorizontalAlignment) end
        if hasMethod(to, "SetVerticalAlignment") then to:SetVerticalAlignment(from.VerticalAlignment) end
        if hasMethod(to, "SetSize") then
            local size = from.Size
            to:SetSize({Value = size.Value, SizeRule = size.SizeRule})
        end
    end
end

function Widgets.replaceControl(row, old, fresh)
    assert(Widgets.valid(old) and Widgets.valid(fresh), "INPUT_CONTROL_MISSING")
    local parent, slot = old:GetParent(), old.Slot
    assert(Widgets.valid(parent) and Widgets.valid(slot), "INPUT_LAYOUT_MISSING")
    if Widgets.is(parent, "ContentWidget") then
        -- SetContent releases the original slot, so copy its values first.
        local padding = hasMethod(slot, "SetPadding") and margin(slot.Padding) or nil
        local horizontal = hasMethod(slot, "SetHorizontalAlignment") and slot.HorizontalAlignment or nil
        local vertical = hasMethod(slot, "SetVerticalAlignment") and slot.VerticalAlignment or nil
        local target = parent:SetContent(fresh)
        assert(Widgets.valid(target), "LAYOUT_SLOT_MISSING")
        if padding then target:SetPadding(padding) end
        if horizontal ~= nil then target:SetHorizontalAlignment(horizontal) end
        if vertical ~= nil then target:SetVerticalAlignment(vertical) end
    else
        Widgets.copySlot(slot, parent:AddChild(fresh))
        old:SetVisibility(Widgets.V.Collapsed)
    end
    local child = fresh
    for _ = 1, 24 do
        if not Widgets.valid(child) then break end
        child:SetIsEnabled(true)
        child:SetVisibility(sameObject(child, fresh) and Widgets.V.Visible or Widgets.V.SelfHitTestInvisible)
        local ancestor = child:GetParent()
        if Widgets.is(ancestor, "WidgetSwitcher") then ancestor:SetActiveWidget(child) end
        if sameObject(child, row) then break end
        child = ancestor
    end
end

local function container(owner, source, owned)
    local kind
    for _, name in ipairs({"CanvasPanel", "Overlay", "SizeBox"}) do
        if Widgets.is(source, name) then kind = name; break end
    end
    assert(kind, "UNSUPPORTED_NATIVE_LAYOUT")
    local copy = Widgets.native(owner, kind)
    owned[#owned + 1] = copy
    if kind == "SizeBox" then
        for _, key in ipairs({"WidthOverride", "HeightOverride", "MinDesiredWidth", "MinDesiredHeight",
            "MaxDesiredWidth", "MaxDesiredHeight", "MinAspectRatio", "MaxAspectRatio"}) do
            if source["bOverride_" .. key] == true then copy["Set" .. key](copy, source[key]) end
        end
    end
    return copy
end

function Widgets.mount(owner, list, details, report)
    local switcher = owner.WidgetSwitcher_65
    assert(Widgets.valid(switcher), "SETTINGS_SWITCHER_NOT_FOUND")
    assert(Widgets.valid(list) and Widgets.valid(details), "SETTINGS_CONTENT_MISSING")
    local copies, owned = {}, {list, details}
    local function copyContainer(source)
        return container(owner, source, owned)
    end
    local ok, result = pcall(function()
        local source, content = owner.ListView_Settings, list
        for _ = 1, 24 do
            local parent = source:GetParent()
            assert(Widgets.valid(parent), "SETTINGS_SWITCHER_NOT_FOUND")
            if sameObject(parent, switcher) then
                Widgets.copySlot(source.Slot, switcher:AddChild(content))
                break
            end
            local copy = copyContainer(parent)
            copies[parent:GetAddress()] = copy
            Widgets.copySlot(source.Slot, copy:AddChild(content))
            source, content = parent, copy
        end
        assert(sameObject(content:GetParent(), switcher), "SETTINGS_LAYOUT_TOO_DEEP")
        local root = content
        local detailSource, detailRoot = owner.Details_Settings, details
        local edges, join = {}, nil
        for _ = 1, 24 do
            local parent = detailSource:GetParent()
            if not Widgets.valid(parent) then break end
            join = copies[parent:GetAddress()]
            if join then break end
            edges[#edges + 1] = {parent = parent, slot = detailSource.Slot}
            detailSource = parent
        end
        local external = false
        if join then
            for _, edge in ipairs(edges) do
                local copy = copyContainer(edge.parent)
                Widgets.copySlot(edge.slot, copy:AddChild(detailRoot))
                detailRoot = copy
            end
            Widgets.copySlot(detailSource.Slot, join:AddChild(detailRoot))
        else
            detailSource = owner.Details_Settings
            local parent = detailSource:GetParent()
            assert(Widgets.valid(parent) and not Widgets.is(parent, "ContentWidget"), "DETAILS_LAYOUT_MISSING")
            Widgets.copySlot(detailSource.Slot, parent:AddChild(detailRoot))
            external = true
        end
        return {root = root, detailRoot = detailRoot, external = external, originalDetails = detailSource}
    end)
    if ok then return result end

    -- A partial attachment is still ours. Clean every created branch independently.
    local removed = {}
    for index = #owned, 1, -1 do
        local widget = owned[index]
        local clean, err = pcall(function()
            if not Widgets.valid(widget) then return end
            local address = widget:GetAddress()
            if removed[address] then return end
            removed[address] = true
            widget:RemoveFromParent()
        end)
        if not clean then
            pcall(function()
                if report then report("LAYOUT_ROLLBACK_FAILED", tostring(err))
                else print("[PbzModConfig] LAYOUT_ROLLBACK_FAILED " .. tostring(err) .. "\n") end
            end)
        end
    end
    error(result, 0)
end

return Widgets
