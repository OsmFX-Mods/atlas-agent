-- Places import: sends places.suggest with locations read from other resources' configs (lib/sandbox.lua).
-- Sources: registered by the adapters (shops, garages, hospitals, police stations, bank tellers).

local cfg = AtlasConfig
local common = AtlasLib.common
local sandbox = AtlasLib.sandbox
local xyz = sandbox.xyz
local radius = cfg.placeRadius

local function add(out, name, kind, v)
    local x, y = xyz(v)
    if x and type(name) == 'string' and name ~= '' then
        out[#out + 1] = { name:sub(1, 64), kind, common.round1(x), common.round1(y), radius[kind] or radius.custom }
    end
end

-- Collect: each active source reads its own configs; one failing source does not stop the others.
local function collect()
    local out = {}
    local function put(name, kind, v) add(out, name, kind, v) end
    for _, def in ipairs(Atlas.sources('places')) do
        local ok, err = pcall(def.read, put)
        if not ok then Atlas.warn('places from %s failed: %s', def.name, tostring(err)) end
    end
    return out
end

--- Suggest: emits places.suggest in chunks of 500 entries.
function Atlas.suggestPlaces(entries)
    for i = 1, #entries, 500 do
        Atlas.emit('places.suggest', { entries = { table.unpack(entries, i, math.min(i + 499, #entries)) } })
    end
end

local function importAll()
    local ok, entries = pcall(collect)
    if not ok then return Atlas.warn('places import failed: %s', tostring(entries)) end
    if #entries > 0 then Atlas.suggestPlaces(entries) end
    Atlas.debug('places: %d suggestions', #entries)
end

-- Debounce: source resources usually start together, so one import covers them.
local pending = false
local function scheduleImport()
    if pending then return end
    pending = true
    CreateThread(function()
        Wait(10000)
        pending = false
        if Atlas.enabled then importAll() end
    end)
end

AddEventHandler('onResourceStart', function(res)
    if Atlas.sourceResources('places')[res] then scheduleImport() end
end)

scheduleImport()
