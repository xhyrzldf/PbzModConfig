-- In-process provider directory. Each UE4SS Lua mod has its own state, so this
-- registry alone is not a cross-mod transport; it is used by a shared host.
local Hub = {}
local function clone(value,seen,depth)
    depth=depth or 0
    local kind=type(value)
    if kind~='table' then
        assert(kind~='userdata' and kind~='thread' and not (kind=='function' and depth>1), 'PROVIDER_NONPLAIN_DATA')
        return value
    end
    seen=seen or {}; assert(not seen[value], 'PROVIDER_CYCLIC_DATA'); seen[value]=true
    local result={}
    for key,item in pairs(value) do
        assert(type(key)=='string' or type(key)=='number', 'PROVIDER_NONPLAIN_KEY')
        result[key]=clone(item,seen,depth+1)
    end
    seen[value]=nil; return result
end
local function validID(value)
    return type(value)=='string' and #value<=96 and value:match('^[A-Za-z][A-Za-z0-9_.-]*$')~=nil
end
local function public(record)
    if not record then return nil end
    return {modId=record.modId,ownerToken=record.ownerToken,descriptor=clone(record.descriptor)}
end

function Hub.create(report)
    report=report or function() end
    local providers,order,listeners,nextId={}, {}, {}, 0
    local self={protocol=1}
    local function diagnostic(code,detail) pcall(report,{code=code,detail=tostring(detail or '')}) end
    local function notify(kind,record,previous)
        local pending={}
        for _,listener in ipairs(listeners) do pending[#pending+1]=listener end
        for _,listener in ipairs(pending) do
            local event={type=kind,record=public(record),previous=public(previous)}
            local ok,err=pcall(listener.callback,event)
            if not ok then diagnostic('DIRECTORY_LISTENER_FAILED',err) end
        end
    end
    function self.publish(descriptor)
        local valid=type(descriptor)=='table' and descriptor.apiVersion==1 and validID(descriptor.modId)
        if valid then
            for _,field in ipairs({'read','apply','subscribe','reset','flush'}) do
                if type(descriptor[field])~='function' then valid=false;break end
            end
        end
        if not valid then diagnostic('INVALID_PROVIDER',type(descriptor)=='table' and descriptor.modId or nil); error('INVALID_PROVIDER',0) end
        local modId=descriptor.modId
        local snapshot=clone(descriptor)
        local previous=providers[modId]
        local record={modId=modId,ownerToken={},descriptor=snapshot}
        if not previous then order[#order+1]=modId else diagnostic('PROVIDER_REPLACED',modId) end
        providers[modId]=record
        notify('published',record,previous)
        local disposed=false
        return {ownerToken=record.ownerToken,dispose=function()
            if disposed then return false end
            disposed=true
            if not providers[modId] or providers[modId].ownerToken~=record.ownerToken then
                diagnostic('STALE_UNREGISTER',modId); return false
            end
            providers[modId]=nil
            for i,id in ipairs(order) do if id==modId then table.remove(order,i);break end end
            notify('removed',record)
            return true
        end}
    end
    function self.subscribeProviders(listener)
        assert(type(listener)=='function', 'INVALID_LISTENER')
        nextId=nextId+1
        local item={id=nextId,callback=listener}; listeners[#listeners+1]=item
        local disposed=false
        return function()
            if disposed then return false end
            disposed=true
            for i,value in ipairs(listeners) do if value.id==item.id then table.remove(listeners,i);return true end end
            return false
        end
    end
    function self.snapshotProviders()
        local result={}
        for _,id in ipairs(order) do result[#result+1]=public(providers[id]) end
        return result
    end
    function self.current(modId) return public(providers[modId]) end
    function self.isCurrent(modId,ownerToken)
        return providers[modId]~=nil and providers[modId].ownerToken==ownerToken
    end
    function self.publishOptional(descriptor)
        local ok,result=pcall(self.publish,descriptor)
        if ok then return result end
        local event={code='REGISTRATION_FAILED',modId=type(descriptor)=='table' and descriptor.modId or nil,detail=tostring(result)}
        pcall(report,event)
        return {error=event,dispose=function() return false end}
    end
    return self
end
return Hub
