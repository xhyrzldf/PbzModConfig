-- Locale selection for materialized settings descriptors. Native calls are
-- injected, so detecting the language never writes game settings or saves.
local Locale = {}
local LATIN_AMERICA = {['419']=true,mx=true,ar=true,bo=true,cl=true,co=true,cr=true,cu=true,
    ['do']=true,ec=true,gt=true,hn=true,ni=true,pa=true,pe=true,pr=true,py=true,sv=true,uy=true,ve=true}
local SIMPLIFIED = {zhs=true,zhhans=true,['zh-cn']=true,['zh-sg']=true,['zh-hans']=true,zh=true}
local TRADITIONAL = {zht=true,zhhant=true,['zh-tw']=true,['zh-hk']=true,['zh-mo']=true,['zh-hant']=true}
local SIGNATURES = {
    {'zhHans','新游戏'}, {'zhHant','新遊戲'}, {'en','NEW GAME'}, {'ko','새 게임'},
    {'ru','НОВАЯ ИГРА'}, {'es-ES','NUEVA PARTIDA'}, {'es-419','NUEVA PARTIDA'}, {'vi','TRÒ CHƠI MỚI'},
}
local REGIONS = {['es-ES']='Flor del recuerdo',['es-419']='Flor de la memoria'}

function Locale.language(value)
    if value == nil or value == '' or value == false then value = 'en' end
    local v = tostring(value):gsub('_', '-'):lower()
    if SIMPLIFIED[v] then return 'zhHans' end
    if TRADITIONAL[v] or v:match('^zh%-hant%-') then return 'zhHant' end
    if v == 'es' or v:match('^es%-') then
        local region = v:match('^es%-([a-z0-9]+)$')
        return region and LATIN_AMERICA[region] and 'es-419' or 'es-ES'
    end
    return v:match('^[^%-]+') or v
end

local function trim(value) return tostring(value):match('^%s*(.-)%s*$') end
local function contains(values, wanted)
    for _, value in ipairs(values) do if value == wanted then return true end end
    return false
end
local function validTag(value)
    if type(value) ~= 'string' then return false end
    local text = trim(value)
    if not text:match('^[A-Za-z][A-Za-z][A-Za-z]?') then return false end
    local first, rest = text:match('^([A-Za-z]+)(.*)$')
    if not first or #first < 2 or #first > 3 then return false end
    while rest ~= '' do
        local part, tail = rest:match('^[-_]([A-Za-z0-9]+)(.*)$')
        if not part or #part < 2 or #part > 8 then return false end
        rest = tail
    end
    return true
end

function Locale.gameLanguage(nativeText, engineLanguage, previous)
    previous = previous or 'zhHans'
    local matches = {}
    local ok, text = pcall(nativeText, 'UI_StartMenu_01')
    if ok and text ~= nil then
        text = trim(text)
        for _, pair in ipairs(SIGNATURES) do
            -- Engine strings use the game's exact authored case. ASCII folding
            -- also accepts lowercase English and Spanish without altering UTF-8.
            if pair[2]:upper() == text:upper() then matches[#matches + 1] = pair[1] end
        end
        if #matches == 1 then return matches[1] end
        if #matches > 1 then
            local regionOk, region = pcall(nativeText, 'UI_Map_20')
            if regionOk and region ~= nil then
                region = trim(region)
                local exact = {}
                for _, id in ipairs(matches) do if REGIONS[id] == region then exact[#exact + 1] = id end end
                if #exact == 1 then return exact[1] end
            end
        end
    end
    local languageOk, language = pcall(engineLanguage)
    if languageOk and validTag(language) then
        local normalized = Locale.language(trim(language))
        if #matches > 1 and not contains(matches, normalized) then
            return contains(matches, previous) and previous or matches[1]
        end
        return normalized
    end
    if #matches > 0 then return contains(matches, previous) and previous or matches[1] end
    return previous
end

function Locale.resolve(value, language)
    if value == nil then return '' end
    if type(value) ~= 'table' then return tostring(value) end
    -- Keys come from JSON; sorting makes an otherwise unspecified fallback deterministic.
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    local normalized = {}
    for _, key in ipairs(keys) do normalized[Locale.language(key)] = value[key] end
    local result = normalized[Locale.language(language)] or normalized.en or normalized.zhHans
    return result or (#keys > 0 and value[keys[1]]) or ''
end
return Locale
