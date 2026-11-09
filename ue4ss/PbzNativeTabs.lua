-- UE4SS port adapted from the existing native-menu prototype.
local Tabs = {}

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function name(value)
    return value:ToString()
end

local function sameObject(left, right)
    if left == nil or right == nil then return left == right end
    return valid(left) and valid(right) and left:GetAddress() == right:GetAddress()
end

local function sameCollectionSlot(left, right)
    local leftValid, rightValid = valid(left), valid(right)
    -- Invalid slots have no usable object identity. Keep their positions and
    -- validity without dereferencing stale objects or comparing Lua wrappers.
    if not leftValid or not rightValid then return leftValid == rightValid end
    return left:GetAddress() == right:GetAddress()
end

local function copy(value)
    -- Out-parameter structs are plain tables. Native FName/FText/UObject leaves
    -- own their values or refer to the UObject, and must retain their userdata.
    if type(value) ~= "table" or getmetatable(value) ~= nil then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function readArray(array)
    local result = {n = array:GetArrayNum()}
    for i = 1, result.n do result[i] = array[i] end
    return result
end

local function readState(panel, tabs)
    local state = {
        collections = readArray(panel.SettingCollections),
        ids = readArray(tabs.TabButtonIDs),
        descriptors = {n = tabs.PreregisteredTabInfoArray:GetArrayNum()},
    }
    local seen = {}
    for i = 1, state.descriptors.n do
        local id = tabs.PreregisteredTabInfoArray[i].TabId
        local key = name(id)
        assert(not seen[key], "DUPLICATE_TAB_DESCRIPTOR: " .. key)
        seen[key] = true
        local descriptor = {}
        assert(tabs:GetPreregisteredTabInfo(id, descriptor), "TAB_SNAPSHOT_FAILED: " .. key)
        assert(descriptor.TabId and name(descriptor.TabId) == key, "TAB_SNAPSHOT_ID_MISMATCH")
        for _, field in ipairs({"TabText", "IconBrush", "SelectedIconBrush", "HasTag"}) do
            assert(type(descriptor[field]) == "table", "TAB_SNAPSHOT_NOT_MATERIALIZED: " .. field)
        end
        state.descriptors[i] = descriptor
    end
    return state
end

local function writeArray(array, values)
    -- UE4SS 1195 grows arrays on both out-of-bounds reads and writes. Only
    -- sequential writes are safe. Its whole-table setter uses unordered iteration.
    array:Empty()
    for i = 1, values.n do array[i] = values[i] end
    assert(array:GetArrayNum() == values.n, "TAB_ARRAY_RESTORE_LENGTH_MISMATCH")
end

local function append(array, value)
    array[array:GetArrayNum() + 1] = value
end

local function without(values, exclude)
    local result = {n = 0}
    for i = 1, values.n do
        if not exclude(values[i], i) then
            result.n = result.n + 1
            result[result.n] = values[i]
        end
    end
    return result
end

local function appended(values, value)
    local result = {n = values.n + 1}
    for i = 1, values.n do result[i] = values[i] end
    result[result.n] = value
    return result
end

-- Dynamic tabs may have no GameSettingCollection. Their native button position
-- is therefore a different coordinate from GetIndexByID's collection mapping.
local function nativeIndex(tabs, key)
    for i = 0, tabs:GetTabCount() - 1 do
        if name(tabs:GetTabIdAtIndex(i)) == key then return i end
    end
    return -1
end

local function metadataMatches(panel, tabs, expected)
    if panel.SettingCollections:GetArrayNum() ~= expected.collections.n
        or tabs.PreregisteredTabInfoArray:GetArrayNum() ~= expected.descriptors.n then return false end
    for i = 1, expected.collections.n do
        if not sameCollectionSlot(panel.SettingCollections[i], expected.collections[i]) then return false end
    end
    for i = 1, expected.descriptors.n do
        if name(tabs.PreregisteredTabInfoArray[i].TabId) ~= name(expected.descriptors[i].TabId) then return false end
    end
    return true
end

-- Native rebuild callbacks can empty this derived lookup. Restore only our last
-- verified mapping, and only while its collections and descriptors still match.
-- A non-empty or independently changed mapping is never overwritten here.
local function restoreEmptyNavigation(panel, tabs, expected)
    if tabs.TabButtonIDs:GetArrayNum() == 0 and expected.ids.n > 0
        and metadataMatches(panel, tabs, expected) then
        writeArray(tabs.TabButtonIDs, expected.ids)
        return true
    end
    return false
end

local function checkState(panel, tabs, expected)
    assert(panel.SettingCollections:GetArrayNum() == expected.collections.n, "TAB_COLLECTION_COUNT_MISMATCH")
    assert(tabs.TabButtonIDs:GetArrayNum() == expected.ids.n, "TAB_ID_COUNT_MISMATCH")
    assert(tabs.PreregisteredTabInfoArray:GetArrayNum() == expected.descriptors.n, "TAB_DESCRIPTOR_COUNT_MISMATCH")
    for i = 1, expected.collections.n do
        assert(sameCollectionSlot(panel.SettingCollections[i], expected.collections[i]), "TAB_COLLECTION_ORDER_MISMATCH")
    end
    for i = 1, expected.ids.n do
        assert(name(tabs.TabButtonIDs[i]) == name(expected.ids[i]), "TAB_ID_ORDER_MISMATCH")
    end
    for i = 1, expected.descriptors.n do
        assert(name(tabs.PreregisteredTabInfoArray[i].TabId) == name(expected.descriptors[i].TabId),
            "TAB_DESCRIPTOR_ORDER_MISMATCH")
    end
end

local function text(value)
    local library = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    assert(valid(library), "TEXT_LIBRARY_MISSING")
    return library:Conv_StringToText(value)
end

local COLLAPSED = 1
function Tabs.spacing(tabs, button)
    local box, native = tabs.TabButtonBox, tabs.TabButtonPadding
    if not valid(box) or not valid(button) or not sameObject(button:GetParent(), box) then error("NATIVE_TAB_LAYOUT_MISMATCH", 0) end
    local previous, found, following = nil, false, false
    for index = 0, box:GetChildrenCount() - 1 do
        local child = box:GetChildAt(index)
        if sameObject(child, button) then found = true
        elseif child:GetVisibility() ~= COLLAPSED then
            if found then following = true; break end
            previous = child
        end
    end
    if not found then error("MOD_TAB_LAYOUT_MISSING", 0) end
    local previousRight = previous and previous.Slot.Padding.Right or 0
    local wanted = {Left = native.Left + (previous and math.max(0, native.Right - previousRight) or 0),
        Top = native.Top, Right = following and native.Right or 0, Bottom = native.Bottom}
    local slot = button.Slot
    local current = slot.Padding
    for _, edge in ipairs({"Left", "Top", "Right", "Bottom"}) do
        if current[edge] ~= wanted[edge] then slot:SetPadding(wanted); break end
    end
    return wanted
end

function Tabs.attach(panel, collection, options)
    options = options or {}
    assert(valid(panel) and valid(collection), "TAB_OWNER_MISSING")
    local collectionAddress = collection:GetAddress()
    local tabs = panel.W_OverlayTabList_C
    assert(valid(tabs), "TAB_LIST_MISSING")
    local id = FName(options.id or "PbzModConfig")
    local key = name(id)
    assert(not valid(tabs:GetTabButtonBaseByID(id)), "MOD_TAB_ALREADY_OWNED")
    local before = readState(panel, tabs)
    assert(before.ids.n == before.collections.n, "NATIVE_TAB_COLLECTION_MISMATCH")
    for i = 1, before.ids.n do
        assert(name(before.ids[i]) ~= key, "MOD_TAB_METADATA_ALREADY_OWNED")
    end
    for i = 1, before.descriptors.n do
        assert(name(before.descriptors[i].TabId) ~= key, "MOD_TAB_METADATA_ALREADY_OWNED")
    end
    for i = 1, before.collections.n do
        assert(not sameObject(before.collections[i], collection), "MOD_COLLECTION_ALREADY_OWNED")
    end
    assert(before.descriptors.n > 0, "NATIVE_TAB_STYLE_MISSING")
    local buttonClass = options.buttonClass
    if not valid(buttonClass) then
        for i = 1, before.ids.n do
            local button = tabs:GetTabButtonBaseByID(before.ids[i])
            if valid(button) then
                buttonClass = button:GetClass()
                break
            end
        end
    end
    assert(valid(buttonClass), "NATIVE_TAB_CLASS_MISSING")
    local style = before.descriptors[1]
    local descriptor = {
        TabId = id,
        bHidden = false,
        TabButtonType = buttonClass,
        TabText = {ValueCache = text(options.text or "模组")},
        IconBrush = copy(style.IconBrush),
        SwitchSound = style.SwitchSound,
    }
    if options.icon ~= nil then
        assert(valid(options.icon), "MOD_TAB_ICON_MISSING")
        descriptor.IconBrush.ResourceObject = options.icon
    end
    local index = before.collections.n
    local buttonIndex = tabs:GetTabCount()
    local expected = {
        collections = appended(before.collections, collection),
        ids = appended(before.ids, id),
        descriptors = appended(before.descriptors, descriptor),
    }

    local function restore(previous, registered, registeredIndex)
        local failures = {}
        local function attempt(label, action)
            local ok, err = pcall(action)
            if not ok then failures[#failures + 1] = label .. " " .. tostring(err) end
        end
        if not registered then
            attempt("remove", function()
                if valid(tabs:GetTabButtonBaseByID(id)) then tabs:RemoveTab(id) end
                assert(not valid(tabs:GetTabButtonBaseByID(id)), "TAB_REMOVE_FAILED")
            end)
        end
        attempt("collections", function() writeArray(panel.SettingCollections, previous.collections) end)
        attempt("descriptors", function() writeArray(tabs.PreregisteredTabInfoArray, previous.descriptors) end)
        attempt("ids", function() writeArray(tabs.TabButtonIDs, previous.ids) end)
        if registered then
            attempt("register", function()
                if valid(tabs:GetTabButtonBaseByID(id)) and nativeIndex(tabs, key) ~= registeredIndex then
                    tabs:RemoveTab(id)
                end
                if not valid(tabs:GetTabButtonBaseByID(id)) then
                    assert(tabs:RegisterTab(id, buttonClass, nil, registeredIndex), "TAB_REGISTER_FAILED")
                end
                assert(valid(tabs:GetTabButtonBaseByID(id)) and nativeIndex(tabs, key) == registeredIndex,
                    "TAB_REGISTRATION_RESTORE_FAILED")
            end)
        end
        attempt("reset", function() tabs:ResetTabSwitchTracking() end)
        attempt("navigation", function() restoreEmptyNavigation(panel, tabs, previous) end)
        attempt("verify", function() checkState(panel, tabs, previous) end)
        return table.concat(failures, " | ")
    end

    local ok, err = pcall(function()
        append(panel.SettingCollections, collection)
        append(tabs.PreregisteredTabInfoArray, descriptor)
        append(tabs.TabButtonIDs, id)
        assert(tabs:RegisterTab(id, buttonClass, nil, buttonIndex), "MOD_TAB_REGISTER_FAILED")
        assert(nativeIndex(tabs, key) == buttonIndex, "MOD_TAB_PAIRING_FAILED")
        restoreEmptyNavigation(panel, tabs, expected)
        assert(valid(tabs:GetTabButtonBaseByID(id)) and tabs:GetIndexByID(id) == index, "MOD_TAB_PAIRING_FAILED")
        assert(panel.SettingCollections:GetArrayNum() == index + 1
            and sameObject(panel.SettingCollections[index + 1], collection), "MOD_COLLECTION_PAIRING_FAILED")
        assert(tabs.TabButtonIDs:GetArrayNum() == index + 1
            and name(tabs.TabButtonIDs[index + 1]) == key, "MOD_NAVIGATION_PAIRING_FAILED")
        assert(tabs.PreregisteredTabInfoArray:GetArrayNum() == before.descriptors.n + 1
            and name(tabs.PreregisteredTabInfoArray[before.descriptors.n + 1].TabId) == key,
            "MOD_DESCRIPTOR_PAIRING_FAILED")
        tabs:ResetTabSwitchTracking()
        restoreEmptyNavigation(panel, tabs, expected)
        checkState(panel, tabs, expected)
    end)
    if not ok then
        local failure = restore(before, false)
        if failure ~= "" then err = tostring(err) .. " | TAB_ROLLBACK_FAILED: " .. failure end
        error(err, 0)
    end

    local scope = {id = id, index = index, button = tabs:GetTabButtonBaseByID(id)}
    local known = expected
    local descriptorIndex = expected.descriptors.n
    local detached, busy = false, false
    -- The panel and the tab list we wrote to must both be alive and still be the same pair. Once that
    -- fails the scope is void for good: nothing of it is touched again, and detach() reports done
    -- (review 2026-11-05, round 6: an owner found dead was retried as an ordinary failure).
    local function owned()
        if detached then return false end
        if valid(panel) and valid(tabs) then
            local current = panel.W_OverlayTabList_C
            if valid(current) and sameObject(current, tabs) then return true end
        end
        detached, panel, tabs, scope.button = true, nil, nil, nil
        return false
    end

    local function collectionIndex(allowDead)
        local ids, collections = tabs.TabButtonIDs, panel.SettingCollections
        if ids:GetArrayNum() ~= collections:GetArrayNum() then return nil end
        local found
        for i = 1, ids:GetArrayNum() do
            if name(ids[i]) == key then
                if found then return nil end
                found = i
            end
        end
        if not found then return nil end
        local matches = 0
        for i = 1, tabs.PreregisteredTabInfoArray:GetArrayNum() do
            if name(tabs.PreregisteredTabInfoArray[i].TabId) == key then
                matches, descriptorIndex = matches + 1, i
            end
        end
        if matches ~= 1 then return nil end
        local value = collections[found]
        if valid(value) then
            if value:GetAddress() ~= collectionAddress then return nil end
        elseif not allowDead then return nil end
        return found
    end

    local function hasCollection()
        for i = 1, panel.SettingCollections:GetArrayNum() do
            local value = panel.SettingCollections[i]
            if valid(value) and value:GetAddress() == collectionAddress then return true end
        end
        return false
    end

    function scope.refresh()
        if not owned() then return false, "TAB_OWNER_DESTROYED" end
        local button = tabs:GetTabButtonBaseByID(id)
        local ids, collections, descriptors = tabs.TabButtonIDs, panel.SettingCollections, tabs.PreregisteredTabInfoArray
        if valid(button) and sameObject(button, scope.button)
            and ids:GetArrayNum() == known.ids.n and collections:GetArrayNum() == known.collections.n
            and descriptors:GetArrayNum() == known.descriptors.n
            and name(ids[scope.index + 1]) == key
            and name(descriptors[descriptorIndex].TabId) == key
            and valid(collections[scope.index + 1])
            and collections[scope.index + 1]:GetAddress() == collectionAddress then return true end
        restoreEmptyNavigation(panel, tabs, known)
        local at = collectionIndex(false)
        if not at then
            if not valid(button) and not hasCollection()
                and ids:GetArrayNum() == collections:GetArrayNum()
                and descriptors:GetArrayNum() == collections:GetArrayNum() then
                local present = false
                for i = 1, ids:GetArrayNum() do if name(ids[i]) == key then present = true end end
                for i = 1, descriptors:GetArrayNum() do
                    if name(descriptors[i].TabId) == key then present = true end
                end
                if not present then return false, "MOD_TAB_REMOVED" end
            end
            return false, "TAB_OWNERSHIP_CHANGED"
        end
        if not valid(button) then return false, "MOD_TAB_REBUILDING" end
        if not sameObject(button:GetClass(), buttonClass) then return false, "TAB_OWNERSHIP_CHANGED" end
        scope.button, scope.index = button, at - 1
        known = readState(panel, tabs)
        return true
    end

    function scope.detach()
        if detached then return false end
        assert(not busy, "TAB_OPERATION_IN_PROGRESS")
        if not owned() then return false end
        restoreEmptyNavigation(panel, tabs, known)
        local at = collectionIndex(true)
        if not at then
            -- The identifier may now belong to another collection. Never remove
            -- that tab. An orphan of our own collection is an incomplete cleanup.
            assert(not hasCollection(), "MOD_TAB_METADATA_INCOMPLETE")
            detached, scope.button = true, nil
            return false
        end
        local previous = readState(panel, tabs)
        local registered = valid(tabs:GetTabButtonBaseByID(id))
        local registeredIndex = registered and nativeIndex(tabs, key) or buttonIndex
        local remaining = {
            collections = without(previous.collections, function(_, i) return i == at end),
            ids = without(previous.ids, function(value) return name(value) == key end),
            descriptors = without(previous.descriptors, function(value) return name(value.TabId) == key end),
        }
        busy = true
        local removed, removeError = pcall(function()
            if registered then tabs:RemoveTab(id) end
            assert(not valid(tabs:GetTabButtonBaseByID(id)), "TAB_REMOVE_FAILED")
            writeArray(panel.SettingCollections, remaining.collections)
            writeArray(tabs.PreregisteredTabInfoArray, remaining.descriptors)
            writeArray(tabs.TabButtonIDs, remaining.ids)
            tabs:ResetTabSwitchTracking()
            restoreEmptyNavigation(panel, tabs, remaining)
            checkState(panel, tabs, remaining)
        end)
        if not removed then
            local failure = restore(previous, registered, registeredIndex)
            scope.button = tabs:GetTabButtonBaseByID(id)
            scope.index = at - 1
            known = previous
            busy = false
            if failure ~= "" then removeError = tostring(removeError) .. " | TAB_ROLLBACK_FAILED: " .. failure end
            error(removeError, 0)
        end
        detached, busy = true, false
        return true
    end
    scope.dispose = scope.detach

    -- Re-label our own tab (language change). Mirrors JS styleTab: the descriptor's
    -- TabText.ValueCache is replaced and the native button restyles itself through
    -- SetTabLabelInfo. Returns true, arrayUpdated. The descriptor array is updated on a
    -- best-effort basis so a later native restyle cannot restore the old text.
    -- Port of JS spaceTab: native UpdateTabStyles clears the last tab's right padding, so appending ours
    -- leaves that slot unchanged. Supply only the missing gap on our own slot (never on native buttons).
    function scope.space()
        assert(not detached and not busy, "TAB_NOT_ATTACHED")
        local ready, reason = scope.refresh()
        assert(ready, reason)
        return Tabs.spacing(tabs, scope.button)
    end

    function scope.setLabel(label)
        assert(not detached and not busy, "TAB_NOT_ATTACHED")
        local ready, reason = scope.refresh()
        assert(ready, reason)
        local button = scope.button
        local info = {}
        assert(tabs:GetPreregisteredTabInfo(id, info), "TAB_SNAPSHOT_FAILED")
        assert(info.TabId and name(info.TabId) == key and type(info.TabText) == "table", "TAB_SNAPSHOT_ID_MISMATCH")
        local value = text(label)
        info.TabText.ValueCache = value
        local updated = pcall(function()
            local array = tabs.PreregisteredTabInfoArray
            for i = 1, array:GetArrayNum() do
                if name(array[i].TabId) == key then
                    array[i].TabText.ValueCache = value
                    return
                end
            end
            error("TAB_DESCRIPTOR_MISSING", 0)
        end)
        button:SetTabLabelInfo(info, false)
        return true, updated
    end
    return scope
end

return Tabs
