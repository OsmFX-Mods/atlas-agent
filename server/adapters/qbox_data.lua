-- Qbox data: the database readers and the places and prices that come with qbx resources.
-- Tables: names come from AtlasConfig.qbox.tables, so servers with renamed tables keep working.

local cfg = AtlasConfig
local common = AtlasLib.common
local sandbox = AtlasLib.sandbox
local db = Atlas.db
local qbx = exports.qbx_core

--- Table: a configured table name as a quoted identifier, nil with a warning when it is not a valid name.
local function tbl(key)
    local name = common.sqlName(cfg.qbox.tables[key])
    if not name then Atlas.warn('config: qbox.tables.%s is not a valid table name', key) end
    return name
end

local CHANGED = 'last_updated >= FROM_UNIXTIME(?)'

--- Page: runs one keyset page and maps each row; returns the rows, the cursor for the next page and the row count.
local function page(sql, params, key, map)
    local rows = db.query(sql, params)
    if type(rows) ~= 'table' then return nil end
    local out = {}
    for i = 1, #rows do out[i] = map(rows[i]) end
    return out, rows[#rows] and rows[#rows][key], #rows
end

-- Money: cash, bank and crypto from the players table; changed rows are found through last_updated.
local money = { delta = true }

function money.count(since)
    local t = tbl('characters')
    if not t then return nil end
    return db.scalar('SELECT COUNT(*) FROM ' .. t .. (since and (' WHERE ' .. CHANGED) or ''), since and { since } or {})
end

function money.page(since, cursor, per)
    local t = tbl('characters')
    if not t then return nil end
    local params = since and { since } or {}
    params[#params + 1] = cursor or ''
    return page(([[SELECT citizenid,
        COALESCE(JSON_EXTRACT(money, '$.cash') + 0, 0) AS cash,
        COALESCE(JSON_EXTRACT(money, '$.bank') + 0, 0) AS bank,
        COALESCE(JSON_EXTRACT(money, '$.crypto') + 0, 0) AS crypto
        FROM %s WHERE %s citizenid > ? ORDER BY citizenid LIMIT %d]]):format(t, since and (CHANGED .. ' AND') or '', per),
        params, 'citizenid', function(r)
            return { r.citizenid, tonumber(r.cash) or 0, tonumber(r.bank) or 0, tonumber(r.crypto) or 0 }
        end)
end

-- Census: player inventories, plus trunks and gloveboxes, which have no change time and are always sent in full.
local function vehicleStorage(column, order)
    return {
        kind = column, order = order,
        count = function()
            local t = tbl('vehicles')
            return t and db.scalar(('SELECT COUNT(*) FROM %s WHERE %s IS NOT NULL'):format(t, column))
        end,
        page = function(_, cursor, per)
            local t = tbl('vehicles')
            if not t then return nil end
            return page(('SELECT id, %s AS d FROM %s WHERE %s IS NOT NULL AND id > ? ORDER BY id LIMIT %d'):format(column, t, column, per),
                { cursor or 0 }, 'id', function(r) return { tostring(r.id), r.d } end)
        end,
    }
end

local players = { kind = 'player', order = 10, delta = true }

function players.count(since)
    local t = tbl('characters')
    if not t then return nil end
    return db.scalar('SELECT COUNT(*) FROM ' .. t .. (since and (' WHERE ' .. CHANGED) or ''), since and { since } or {})
end

function players.page(since, cursor, per)
    local t = tbl('characters')
    if not t then return nil end
    local params = since and { since } or {}
    params[#params + 1] = cursor or ''
    return page(('SELECT citizenid, inventory FROM %s WHERE %s citizenid > ? ORDER BY citizenid LIMIT %d'):format(
        t, since and (CHANGED .. ' AND') or '', per), params, 'citizenid', function(r)
        return { r.citizenid, r.inventory or '[]' }
    end)
end

-- Vehicles: owner, model hash and plate hash per owned vehicle.
local vehicles = { owned = {} }

function vehicles.census()
    local t = tbl('vehicles')
    if not t then return nil end
    local rows = db.query(('SELECT vehicle, COUNT(*) AS n FROM %s GROUP BY vehicle'):format(t))
    if type(rows) ~= 'table' then return nil end
    local out = {}
    for i = 1, #rows do out[i] = { tostring(rows[i].vehicle), tonumber(rows[i].n) or 0 } end
    return out
end

function vehicles.owned.count()
    local t = tbl('vehicles')
    return t and db.scalar(('SELECT COUNT(*) FROM %s WHERE citizenid IS NOT NULL'):format(t))
end

function vehicles.owned.page(cursor, per)
    local t = tbl('vehicles')
    if not t then return nil end
    return page(('SELECT id, citizenid, hash, vehicle, plate FROM %s WHERE citizenid IS NOT NULL AND id > ? ORDER BY id LIMIT %d'):format(t, per),
        { cursor or 0 }, 'id', function(r)
            local model = tonumber(r.hash)
            if not model and type(r.vehicle) == 'string' then model = GetHashKey(r.vehicle) end
            local plate = common.plate(r.plate)
            return { r.citizenid, model and common.u32(model) or 0, plate and common.u32(GetHashKey(plate)) or 0 }
        end)
end

Atlas.frameworkData.qbox = {
    money = money,
    census = function()
        -- Inventories: qbx keeps them in ox_inventory format, so without it there is nothing to read
        if GetResourceState('ox_inventory') ~= 'started' then return nil end
        return { players, vehicleStorage('trunk', 30), vehicleStorage('glovebox', 40) }
    end,
    vehicles = vehicles,
    -- Groups: job and gang names, used to classify Renewed-Banking accounts
    groups = function()
        local jobs, gangs = {}, {}
        local ok, j = pcall(qbx.GetJobs, qbx)
        if ok and type(j) == 'table' then for name in pairs(j) do jobs[name] = true end end
        local ok2, g = pcall(qbx.GetGangs, qbx)
        if ok2 and type(g) == 'table' then for name in pairs(g) do gangs[name] = true end end
        return jobs, gangs
    end,
}

-- Places: garages, hospitals and police stations.
Atlas.registerSource('places', {
    name = 'qbx_garages',
    resources = { 'qbx_garages' },
    read = function(add)
        local ok, garages = pcall(function() return exports.qbx_garages:GetGarages() end)
        if not ok or type(garages) ~= 'table' then return end
        for id, g in pairs(garages) do
            if type(g) == 'table' and type(g.accessPoints) == 'table' and g.accessPoints[1] then
                local ap = g.accessPoints[1]
                add(type(g.label) == 'string' and g.label or tostring(id), 'garage', ap.coords or ap.spawn)
            end
        end
    end,
})

Atlas.registerSource('places', {
    name = 'qbx_ambulancejob',
    resources = { 'qbx_ambulancejob' },
    read = function(add)
        local conf = Atlas.loadConfig('qbx_ambulancejob', 'config/shared.lua')
        local hospitals = type(conf) == 'table' and type(conf.locations) == 'table' and conf.locations.hospitals
        if type(hospitals) ~= 'table' then return end
        for id, h in pairs(hospitals) do
            if type(h) == 'table' then add(tostring(id), 'hospital', h.coords) end
        end
    end,
})

Atlas.registerSource('places', {
    name = 'qbx_police',
    resources = { 'qbx_police' },
    read = function(add)
        local conf = Atlas.loadConfig('qbx_police', 'config/shared.lua')
        local stations = type(conf) == 'table' and type(conf.locations) == 'table' and conf.locations.stations
        if type(stations) ~= 'table' then return end
        for _, st in sandbox.items(stations) do
            if type(st) == 'table' then add(st.label, 'police', st.coords) end
        end
    end,
})

-- Prices: vehicles from qbx_core and properties for sale from qbx_properties.
Atlas.registerSource('prices', {
    name = 'qbx_vehicles',
    resources = { 'qbx_core' },
    read = function(emit)
        local ok, list = pcall(function() return exports.qbx_core:GetVehiclesByName() end)
        if not ok or type(list) ~= 'table' then return end
        local entries = {}
        for model, v in pairs(list) do
            if type(v) == 'table' and tonumber(v.price) then
                local label = ((v.brand or '') .. ' ' .. (v.name or model)):gsub('^%s+', '')
                local shop = v.shop
                if type(shop) == 'table' then shop = shop[1] end
                entries[#entries + 1] = {
                    tostring(model), label, tonumber(v.price),
                    type(shop) == 'string' and shop or '',
                    type(v.category) == 'string' and v.category or '',
                }
            end
        end
        table.sort(entries, function(a, b) return a[1] < b[1] end)
        emit('vehicle', entries)
    end,
})

Atlas.registerSource('prices', {
    name = 'qbx_properties',
    resources = { 'qbx_properties' },
    read = function(emit)
        local t = tbl('properties')
        if not t or not db.available() then return end
        -- Sale only: rentals and free apartments (price 0) are skipped
        local rows = db.query(('SELECT id, property_name, price FROM %s WHERE price > 0 AND rent_interval IS NULL ORDER BY id LIMIT 5000'):format(t))
        if type(rows) ~= 'table' or #rows == 0 then return end
        local entries = {}
        for i = 1, #rows do
            entries[i] = { tostring(rows[i].id), tostring(rows[i].property_name or ''), tonumber(rows[i].price) or 0, '', 'property' }
        end
        emit('property', entries)
    end,
})
