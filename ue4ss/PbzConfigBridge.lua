-- Connect a same-state provider directory to the native settings UI. Providers
-- may be registered or removed independently; stale callbacks cannot write to
-- a replacement. The caller schedules every rebuild on the game thread.
local Bridge={}
local ALLOWED={header=true,toggle=true,choice=true,number=true,action=true,keybind=true,color=true,sound=true}
-- Returns true plus the list of entries the menu can show. Like the JS framework, a control of
-- an unknown type is skipped (reported by the caller) while the rest of the mod stays usable.
local function compatible(provider)
    if type(provider)~='table' or type(provider.modId)~='string' or #provider.modId>96
        or not provider.modId:match('^[A-Za-z][A-Za-z0-9_.-]*$')
        or type(provider.entries)~='table' or type(provider.groups)~='table'
        or type(provider.read)~='function' or type(provider.apply)~='function'
        or type(provider.flush)~='function' then return false,'PROVIDER_INVALID' end
    local groups,keys,skipped,entries={},{},{},{}
    for _,group in ipairs(provider.groups) do
        if type(group.id)~='string' or groups[group.id] then return false,'PROVIDER_GROUP_INVALID' end
        groups[group.id]=true
    end
    for _,entry in ipairs(provider.entries) do
        if type(entry.key)~='string' or keys[entry.key] then return false,'PROVIDER_ENTRY_INVALID' end
        if entry.group and not groups[entry.group] then return false,'PROVIDER_GROUP_UNKNOWN' end
        keys[entry.key]=true
        if ALLOWED[entry.type] then entries[#entries+1]=entry else skipped[#skipped+1]=entry end
    end
    for _,entry in ipairs(entries) do
        for _,rule in ipairs({entry.enabledWhen or false,entry.visibleWhen or false}) do
            if rule then
                for _,other in ipairs(skipped) do
                    if other.key==rule.key then return false,'PROVIDER_CONDITION_TARGET_UNSUPPORTED '..entry.key end
                end
            end
        end
    end
    return true,nil,entries,skipped
end
local function guarded(hub,record,entries)
    local original=record.descriptor
    local result={}
    for key,value in pairs(original) do result[key]=value end
    result.entries=entries or original.entries
    for _,key in ipairs({'read','apply','subscribe','reset','flush','invokeAction','previewSound','createVisualPreview'}) do
        local action=original[key]
        if type(action)=='function' then
            result[key]=function(...)
                assert(hub.isCurrent(record.modId,record.ownerToken), 'STALE_PROVIDER')
                return action(...)
            end
        end
    end
    return result
end

function Bridge.start(hub,deps)
    assert(type(hub)=='table' and type(hub.snapshotProviders)=='function'
        and type(hub.subscribeProviders)=='function' and type(hub.current)=='function' and type(hub.isCurrent)=='function', 'PROVIDER_HUB_REQUIRED')
    assert(type(deps)=='table' and type(deps.startRuntime)=='function' and type(deps.schedule)=='function', 'BRIDGE_DEPS_INVALID')
    local stopped,queued,runtime=false,false,nil
    local report=deps.report or function() end
    local function log(code,detail) pcall(report,code,tostring(detail or '')) end
    -- Runtimes that replied false/raised when asked to stop. They keep their native resources until a
    -- later stop succeeds; the bridge must not claim to be stopped meanwhile.
    local retired={}
    -- A runtime releases itself completely on stop() or answers false/raises (nil counts as released).
    local function release(target,force)
        local ok,result=pcall(target.stop,force)
        if ok and result~=false then return true end
        log('BRIDGE_STOP_FAILED',ok and 'runtime reported an incomplete release' or result)
        return false
    end
    local sync
    local function requestSync()
        if stopped or queued then return end
        queued=true
        local ok,err=pcall(deps.schedule,function()
            queued=false
            if not stopped then sync() end
        end)
        if not ok then queued=false;log('BRIDGE_SCHEDULE_FAILED',err) end
    end
    -- A rebuild while a dialog or sub-page is open would drop it (JS refuses to reload then). The
    -- runtime says when it is idle again and the pending sync runs.
    local deferred=false
    local runtimeOptions={}
    for key,value in pairs(deps.runtimeOptions or {}) do runtimeOptions[key]=value end
    local userIdle=runtimeOptions.onIdle
    runtimeOptions.onIdle=function()
        if type(userIdle)=='function' then pcall(userIdle) end
        if deferred then deferred=false;requestSync() end
    end
    local function busy()
        return runtime~=nil and type(runtime.busy)=='function' and select(2,pcall(runtime.busy))==true
    end
    sync=function()
        if busy() then
            deferred=true;log('BRIDGE_RELOAD_DEFERRED','a dialog is open');return
        end
        local providers,seen={},{}
        for _,record in ipairs(hub.snapshotProviders()) do
            local current=hub.current(record.modId)
            -- Directory callbacks are synchronous and may reenter. Only the
            -- currently owned provider is eligible for a new UI instance.
            if current and current.ownerToken==record.ownerToken then
                local ok,why,entries,skipped=compatible(record.descriptor)
                if ok and not seen[record.modId] then
                    seen[record.modId]=true; providers[#providers+1]=guarded(hub,record,entries)
                    for _,entry in ipairs(skipped) do log('UNKNOWN_CONTROL',record.modId..' '..entry.key..' '..tostring(entry.type)) end
                else log('PROVIDER_SKIPPED',record.modId..' '..tostring(why or 'DUPLICATE')) end
            end
        end
        local ok,nextRuntime=pcall(deps.startRuntime,providers,runtimeOptions)
        if not ok or type(nextRuntime)~='table' or type(nextRuntime.stop)~='function' then
            log('BRIDGE_RUNTIME_FAILED',nextRuntime);return
        end
        local old=runtime
        runtime=nextRuntime
        for index=#retired,1,-1 do
            if retired[index]~=runtime and release(retired[index]) then table.remove(retired,index) end
        end
        if old and old~=runtime and not release(old) then retired[#retired+1]=old end
        if deps.onReady then
            local notified,err=pcall(deps.onReady,#providers)
            if not notified then log('BRIDGE_READY_CALLBACK_FAILED',err) end
        end
    end
    local unsubscribe=hub.subscribeProviders(requestSync)
    assert(type(unsubscribe)=='function', 'BRIDGE_SUBSCRIBE_FAILED')
    requestSync()
    local self={}
    -- True once every runtime this bridge started has released its resources. On false nothing is
    -- forgotten: the subscription stays and a later stop() retries the unreleased runtimes.
    function self.busy() return busy() end
    -- opts.force stops even while a dialog is open. False: nothing was dropped, retry later.
    function self.stop(opts)
        if stopped then return true end
        local force=type(opts)=='table' and opts.force==true
        if not force and busy() then
            log('MOD_CONFIG_DIALOG_ACTIVE','stop refused while a dialog is open');return false
        end
        local clean=true
        if runtime and not release(runtime,force) then clean=false end
        for index=#retired,1,-1 do
            if release(retired[index],force) then table.remove(retired,index) else clean=false end
        end
        if not clean then return false end
        stopped=true;unsubscribe()
        runtime=nil
        return true
    end
    return self
end
return Bridge
