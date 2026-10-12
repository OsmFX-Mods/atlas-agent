-- Places import: sends places.suggest with locations read from other resources' configs through lib/sandbox.lua.
-- Sources: ox_inventory shops, qbx_garages, qbx_ambulancejob hospitals, qbx_police stations, Renewed-Banking tellers.

local sandbox = AtlasLib.sandbox
local xyz = sandbox.xyz

local function loadFile(res, path)
    if GetResourceState(res) == 'missing' then return nil end
    local src = LoadResourceFile(res, path)
    if not src then return nil end
    local result, env, err = sandbox.load(src, res .. '/' .. path, Atlas.vectorCtors())
    if err then Atlas.debug('places: could not read %s/%s: %s', res, path, tostring(err)) end
    return result, env
end

--- Shop definitions: ox_inventory shops, also read by prices.catalog.
function Atlas.loadOxShops()
    local shops = loadFile('ox_inventory', 'data/shops.lua')
    return type(shops) == 'table' and shops or nil
end

local function add(out, name, kind, v, radius)
    local x, y = xyz(v)
    if x and type(name) == 'string' and name ~= '' then
        out[#out + 1] = { name:sub(1, 64), kind, math.floor(x * 10 + 0.5) / 10, math.floor(y * 10 + 0.5) / 10, radius }
    end
end

local function collect()
    local out = {}

    local shops = Atlas.loadOxShops()
    if shops then
        for id, shop in pairs(shops) do
            if type(shop) == 'table' then
                local name = type(shop.name) == 'string' and shop.name or tostring(id)
                if type(shop.locations) == 'table' then
                    for _, loc in sandbox.items(shop.locations) do add(out, name, 'shop', loc, 15.0) end
                elseif type(shop.targets) == 'table' then
                    for _, t in sandbox.items(shop.targets) do add(out, name, 'shop', type(t) == 'table' and (t.loc or t.coords), 15.0) end
                end
            end
        end
    end

    if GetResourceState('qbx_garages') == 'started' then
        local ok, garages = pcall(function() return exports.qbx_garages:GetGarages() end)
        if ok and type(garages) == 'table' then
            for id, g in pairs(garages) do
                if type(g) == 'table' and type(g.accessPoints) == 'table' and g.accessPoints[1] then
                    local ap = g.accessPoints[1]
                    add(out, type(g.label) == 'string' and g.label or tostring(id), 'garage', ap.coords or ap.spawn, 30.0)
                end
            end
        end
    end

    local amb = loadFile('qbx_ambulancejob', 'config/shared.lua')
    if type(amb) == 'table' and type(amb.locations) == 'table' and type(amb.locations.hospitals) == 'table' then
        for id, h in pairs(amb.locations.hospitals) do
            if type(h) == 'table' then add(out, tostring(id), 'hospital', h.coords, 40.0) end
        end
    end

    local pol = loadFile('qbx_police', 'config/shared.lua')
    if type(pol) == 'table' and type(pol.locations) == 'table' and type(pol.locations.stations) == 'table' then
        for _, st in sandbox.items(pol.locations.stations) do
            if type(st) == 'table' then add(out, st.label, 'police', st.coords, 40.0) end
        end
    end

    local _, env = loadFile('Renewed-Banking', 'config.lua')
    local bankCfg = env and rawget(env, 'Config')
    if type(bankCfg) == 'table' and type(bankCfg.peds) == 'table' then
        for _, ped in sandbox.items(bankCfg.peds) do
            if type(ped) == 'table' then add(out, 'Bank', 'bank', ped.coords, 20.0) end
        end
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

local SOURCES = { ox_inventory = true, qbx_garages = true, qbx_ambulancejob = true, qbx_police = true, ['Renewed-Banking'] = true }

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
    if SOURCES[res] then scheduleImport() end
end)

scheduleImport()
