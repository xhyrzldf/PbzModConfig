-- Wrap a Lua configuration store as an in-process ModConfig provider.
-- This does not make separate UE4SS Lua states share memory; a transport or
-- shared host still has to supply one common owner for every participant.
local Provider = {}
local function copy(value,seen)
    if type(value)~='table' then return value end
    seen=seen or {}; assert(not seen[value], 'CONFIG_CYCLIC_VALUE'); seen[value]=true
    local result={}
    for key,item in pairs(value) do result[key]=copy(item,seen) end
    seen[value]=nil; return result
end
local function changed(a,b)
    if a.revision~=b.revision then return true end
    local left,right=a.persistence or {},b.persistence or {}
    return left.state~=right.state or left.error~=right.error
end

function Provider.create(store,schema,options)
    options=options or {}
    assert(type(store)=='table' and type(store.read)=='function' and type(store.apply)=='function'
        and type(store.flush)=='function', 'PROVIDER_STORE_INVALID')
    assert(type(schema)=='table' and type(schema.modId)=='string' and type(schema.groups)=='table'
        and type(schema.entries)=='table', 'PROVIDER_SCHEMA_INVALID')
    local groups={}
    for _,group in ipairs(schema.groups) do
        assert(type(group.id)=='string' and not groups[group.id], 'PROVIDER_GROUP_INVALID')
        groups[group.id]=true
    end
    local listeners,nextId={},0
    local report=options.report or function() end
    local function snapshot()
        local value=store.read()
        assert(type(value)=='table' and type(value.revision)=='number' and type(value.values)=='table', 'PROVIDER_SNAPSHOT_INVALID')
        return copy(value)
    end
    local function notify(value,origin)
        local queued={}
        for _,item in ipairs(listeners) do queued[#queued+1]=item end
        for _,item in ipairs(queued) do
            local event=copy(value); event.origin=origin
            local ok,err=pcall(item.callback,event)
            if not ok then pcall(report,'PROVIDER_LISTENER_FAILED',tostring(err)) end
        end
    end
    local self={apiVersion=1,modId=schema.modId,modVersion=options.modVersion or 'development',
        schemaVersion=options.schemaVersion,displayName=copy(schema.displayName or schema.modId),
        groups=copy(schema.groups),entries=copy(schema.entries)}
    self.read=snapshot
    function self.subscribe(listener)
        assert(type(listener)=='function', 'PROVIDER_LISTENER_INVALID')
        nextId=nextId+1
        local item={id=nextId,callback=listener}; listeners[#listeners+1]=item
        local disposed=false
        return function()
            if disposed then return false end
            disposed=true
            for i,value in ipairs(listeners) do if value.id==item.id then table.remove(listeners,i); return true end end
            return false
        end
    end
    function self.apply(patch,context)
        local before=snapshot()
        local result=store.apply(patch,context)
        local after=snapshot()
        if changed(before,after) then notify(after,context and context.origin or nil) end
        return copy(result)
    end
    function self.flush()
        local before=snapshot()
        local result=store.flush()
        local after=snapshot()
        if changed(before,after) then notify(after,'flush') end
        return copy(result)
    end
    function self.reset(groupId,context)
        if groupId~=nil and not groups[groupId] then
            local result=snapshot(); result.ok=false; result.error='UNKNOWN_GROUP'; return result
        end
        local patch={}
        for _,entry in ipairs(schema.entries) do
            if entry.defaultValue~=nil and (groupId==nil or entry.group==groupId) then
                patch[entry.key]=entry.defaultValue
            end
        end
        if context~=nil and type(context)~='table' then return self.apply(patch,context) end
        local resetContext=copy(context or {})
        if not resetContext.origin then resetContext.origin='reset' end
        return self.apply(patch,resetContext)
    end
    if options.invokeAction then self.invokeAction=options.invokeAction end
    return self
end
return Provider
