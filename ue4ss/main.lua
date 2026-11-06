-- ModConfig for UE4SS: the shared "Mods" settings page and the cross-mod host. It owns no
-- settings of its own; other UE4SS mods (the map tracker among them) register through
-- PbzModConfigClient. All game access runs on the game thread.
local function report(code, detail)
    print('[PbzModConfig] ' .. code .. ' ' .. tostring(detail or '') .. '\n')
end
local HOST_SLOT = '__PBZ_SHARED_HOST_V1__'
-- Directory of this file, e.g. .../Mods/PbzModConfig/Scripts (used for bundled assets).
local scriptsDir = (debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/'):match('^(.*)/[^/]*$')) or '.'
local function defaultObject(path)
    local object = StaticFindObject(path)
    assert(object and object:IsValid(), 'LOCALE_LIBRARY_UNAVAILABLE ' .. path)
    return object
end
local function asString(value)
    if type(value) == 'string' then return value end
    return value:ToString()
end
local function nativeText(key)
    local library = defaultObject('/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary')
    return asString(library:MakeTextByKey(key))
end
local function engineLanguage()
    local library = defaultObject('/Script/Engine.Default__KismetInternationalizationLibrary')
    return asString(library:GetCurrentLanguage())
end

if type(ExecuteInGameThread) ~= 'function' or type(ExecuteInGameThreadWithDelay) ~= 'function' then
    report('START_FAILED', 'Required game-thread scheduling API is unavailable')
    return
end

-- build_test.py rewrites these two lines; a player build keeps them exactly as written.
local Dev = nil -- PBZ_DEV_CONFIG
local Capabilities = {} -- PBZ_CAPABILITIES
local Bridge = Dev and Dev.bridgeRoot and require('PbzDevBridge') or nil
if Bridge then Bridge.prepare(Dev.bridgeRoot) end

local function boot()
    local monitor, host
    local ok, err = xpcall(function()
        local words = require('PbzFrameworkStrings')
        local LocaleMonitor = require('PbzLocaleMonitor')
        local Runtime = require('PbzModConfigRuntime')
        local Host = require('PbzSharedHost')
        local previous = rawget(_G, HOST_SLOT)
        assert(not previous or type(previous.stop)=='function', 'HOST_SLOT_ALREADY_OWNED')
        if previous then assert(previous.stop(), 'PREVIOUS_HOST_STOP_FAILED') end
        monitor = LocaleMonitor.start({nativeText=nativeText, engineLanguage=engineLanguage,
            schedule=ExecuteInGameThreadWithDelay, report=report})
        host = Host.create({schedule=ExecuteInGameThread, startRuntime=Runtime.start, report=report,
            onMenuReady=function(count) report('READY', 'providers=' .. count) end})
        local stopHost = host.stop
        host.stop = function()
            local stopped = stopHost()
            if stopped then
                monitor.stop()
                if rawget(_G, HOST_SLOT)==host then rawset(_G, HOST_SLOT, nil) end
            end
            return stopped
        end
        -- Native capabilities stay off until an in-game probe confirms them.
        local capabilities = Capabilities
        if Bridge then
            -- Test builds only: the bridge overlay may switch capabilities between reloads.
            local found, override = pcall(require, 'PbzCapabilities')
            if found then assert(type(override) == 'table', 'DEV_CAPABILITIES_INVALID'); capabilities = override end
        end
        local apiBuilt, menuApi = pcall(function()
            return require('PbzNativeApi').create({capabilities = capabilities, report = report, scriptsDir = scriptsDir,
                wheelPath = Dev and Dev.bridgeRoot and (Dev.bridgeRoot .. '/assets/color-wheel.png') or nil,
                tabIcon = Runtime.textureImporter})
        end)
        if not apiBuilt then report('NATIVE_API_UNAVAILABLE', menuApi); menuApi = {} end
        host.enableMenu({report = report, tabText = words.tab, words = words, capabilities = capabilities, api = menuApi,
            localeResolver = function(value) return monitor.resolve(value) end})
        -- Other mods register through UE4SS shared variables (PbzModConfigClient); the settings
        -- page still opens, empty, when that channel is unavailable.
        local remoteOk, remote = pcall(function()
            local Remote = require('PbzRemoteHost')
            local RemoteClient = require('PbzModConfigClient')
            return Remote.start({shared = RemoteClient.modRefShared(), host = host, report = report})
        end)
        if remoteOk then host.attachPlugin(remote) else report('REMOTE_HOST_UNAVAILABLE', remote) end
        rawset(_G, HOST_SLOT, host)
        report('HOST_INITIALIZED', 'version=' .. tostring(require('PbzModConfigMetadata').version) .. ' remote=' .. tostring(remoteOk))
    end, debug.traceback)
    if not ok then
        if host then pcall(host.stop) end
        if monitor then monitor.stop() end
        report('START_FAILED', err)
    end
    return ok
end

local scheduled, scheduleError = pcall(ExecuteInGameThread, function()
    boot()
    if Bridge then
        Bridge.start({root=Dev.bridgeRoot, schedule=ExecuteInGameThreadWithDelay, log=report, ctx={
            report=report,
            host=function() return rawget(_G, HOST_SLOT) end,
            -- Stops the host (and its plugins), forgets loaded modules and boots again, so
            -- files placed in the bridge overlay take effect without restarting the game.
            reload=function()
                local host = rawget(_G, HOST_SLOT)
                if host then assert(host.stop(), 'HOST_STOP_FAILED') end
                for name in pairs(package.loaded) do
                    if name:match('^Pbz') and name ~= 'PbzDevBridge' then
                        package.loaded[name] = nil
                    end
                end
                return boot()
            end,
        }})
    end
end)
if not scheduled then report('START_FAILED', scheduleError) end
