-- Single UE4SS Lua host for optional map and settings modules. It does not
-- pretend that another UE4SS mod's independent Lua state shares this registry.
local Hub=require('PbzProviderHub')
local StoreProvider=require('PbzStoreProvider')
local Bridge=require('PbzConfigBridge')
local Host={}
-- Optional so a package without the module keeps logging the old way.
local loaded,Diagnostics=pcall(require,'PbzDiagnostics')
if not loaded then Diagnostics=nil end
local devBuild
local function isDevBuild()
    if devBuild==nil then devBuild=type(package.searchpath)=='function' and package.searchpath('PbzDevBridge',package.path)~=nil end
    return devBuild
end
function Host.create(deps)
    deps=deps or {}
    -- Every report is counted in memory (K06). Test builds (dev bridge present, deps.verbose or the
    -- verboseLog capability) also print each line; a player build prints only the first occurrence of
    -- each code, without the raw error text.
    local rawReport=deps.report or function() end
    local diagnostics,forceVerbose=nil,deps.verbose==true
    local report=rawReport
    if Diagnostics then
        diagnostics=Diagnostics.create({version=deps.version})
        report=Diagnostics.sink(diagnostics,rawReport,function() return forceVerbose or isDevBuild() end)
    end
    local hub=Hub.create(function(event) pcall(report,event.code,event.detail) end)
    local registrations,plugins,bridge,stopped={}, {}, nil,false
    local self={}
    function self.providers() return hub.snapshotProviders() end
    -- Bounded counters of everything reported through the host (nil without the diagnostics module).
    function self.diagnostics() return diagnostics and diagnostics.snapshot() or nil end
    local function active() assert(not stopped,'HOST_STOPPED') end
    function self.registerProvider(provider)
        active()
        assert(type(provider)=='table' and type(provider.modId)=='string','PROVIDER_INVALID')
        local previous=hub.current(provider.modId)
        if previous then
            for _,entry in ipairs(registrations) do
                if entry.modId==provider.modId and entry.ownerToken==previous.ownerToken then
                    assert(entry.flushOwned(),'PROVIDER_REPLACEMENT_SAVE_FAILED')
                    assert(hub.isCurrent(provider.modId,previous.ownerToken),'PROVIDER_REPLACED_DURING_SAVE')
                    break
                end
            end
        end
        local registration=hub.publish(provider)
        local id,token=provider.modId,registration.ownerToken
        if stopped then registration.dispose();error('HOST_STOPPED',0) end
        local proxy={}
        for key,value in pairs(provider) do proxy[key]=value end
        for _,name in ipairs({'read','apply','subscribe','reset','flush','invokeAction','previewSound','createVisualPreview'}) do
            local action=provider[name]
            if type(action)=='function' then
                proxy[name]=function(...)
                    assert(hub.isCurrent(id,token),'STALE_PROVIDER')
                    return action(...)
                end
            end
        end
        local function flushOwned()
            if not hub.isCurrent(id,token) then return true end
            -- Message-backed providers (cross-mod proxies) can only request a save; the
            -- owning mod writes its own files and confirms asynchronously.
            if provider.async==true then pcall(provider.flush);return true end
            local ok,result=pcall(provider.flush)
            if not ok or type(result)~='table' or result.ok~=true
                or not result.persistence or result.persistence.state~='saved' then
                pcall(report,'HOST_FLUSH_FAILED',ok and tostring(result and result.error or 'SAVE_FAILED') or tostring(result))
                return false
            end
            local readOk,current=pcall(provider.read)
            if not readOk or type(current)~='table' or not current.persistence or current.persistence.state~='saved'
                or current.revision~=result.revision then
                pcall(report,'HOST_FLUSH_FAILED','SAVE_CHANGED_DURING_FLUSH')
                return false
            end
            return true
        end
        local handle={provider=proxy,ownerToken=token,flushOwned=flushOwned,dispose=function()
            if not hub.isCurrent(id,token) then return registration.dispose() end
            if not flushOwned() then return false end
            return registration.dispose()
        end}
        registrations[#registrations+1]={modId=id,ownerToken=token,flushOwned=flushOwned,revoke=registration.dispose}
        return handle
    end
    function self.registerStore(store,schema,options)
        active()
        return self.registerProvider(StoreProvider.create(store,schema,options))
    end
    function self.attachPlugin(plugin)
        active()
        assert(type(plugin)=='table' and type(plugin.stop)=='function', 'HOST_PLUGIN_INVALID')
        plugins[#plugins+1]={plugin=plugin,stopped=false}
        return plugin
    end
    function self.enableMenu(options)
        active()
        if bridge then return false end
        assert(type(deps.schedule)=='function' and type(deps.startRuntime)=='function', 'HOST_MENU_UNAVAILABLE')
        local menuOptions={}
        for key,value in pairs(options or {}) do menuOptions[key]=value end
        if type(menuOptions.capabilities)=='table' and menuOptions.capabilities.verboseLog==true then forceVerbose=true end
        menuOptions.report=report
        bridge=Bridge.start(hub,{schedule=deps.schedule,startRuntime=deps.startRuntime,
            runtimeOptions=menuOptions,report=report,onReady=deps.onMenuReady})
        return true
    end
    function self.disableMenu()
        active()
        if not bridge then return false end
        local ok,result=pcall(bridge.stop)
        if not ok or result==false then
            pcall(report,'HOST_MENU_STOP_FAILED',ok and 'incomplete release' or tostring(result))
            return false
        end
        bridge=nil;return true
    end
    -- opts.force stops even while the settings page shows a dialog. Without it the host refuses
    -- (false, nothing released) so a reload cannot drop a confirmation the player is answering.
    function self.stop(opts)
        if stopped then return false end
        local force=type(opts)=='table' and opts.force==true
        if bridge and not force and bridge.busy() then
            pcall(report,'HOST_BUSY','a dialog is open on the settings page');return false
        end
        for _,handle in ipairs(registrations) do if not handle.flushOwned() then return false end end
        for index=#plugins,1,-1 do
            local entry=plugins[index]
            if not entry.stopped then
                local ok,result=pcall(entry.plugin.stop)
                if not ok or result~=true then pcall(report,'HOST_PLUGIN_STOP_FAILED',tostring(result));return false end
                entry.stopped=true
            end
        end
        -- The settings page must release its native resources before the host reports a stop.
        if bridge then
            local ok,result=pcall(bridge.stop,{force=force})
            if not ok or result==false then
                pcall(report,'HOST_MENU_STOP_FAILED',ok and 'incomplete release' or tostring(result))
                return false
            end
            bridge=nil
        end
        stopped=true
        for index=#registrations,1,-1 do
            local ok,err=pcall(registrations[index].revoke)
            if not ok then pcall(report,'HOST_DISPOSE_FAILED',tostring(err)) end
        end
        registrations,plugins={},{};return true
    end
    return self
end
return Host
