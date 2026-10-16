-- ESX data: the database readers and the places and prices that come with ESX resources.
-- Tables and accounts: names come from AtlasConfig.esx, so renamed tables and custom accounts keep working.
-- Accounts: ESX keeps them as JSON in the users table, so they are decoded here instead of in SQL.

local cfg = AtlasConfig
local common = AtlasLib.common
local sandbox = AtlasLib.sandbox
local db = Atlas.db

--- Table: a configured table name as a quoted identifier, nil with a warning when it is not a valid name.
local function tbl(key)
    local name = common.sqlName(cfg.esx.tables[key])
    if not name then Atlas.warn('config: esx.tables.%s is not a valid table name', key) end
    return name
end

local SLOTS = { cash = true, bank = true, crypto = true }

--- Slots: sums account balances into the cash, bank and crypto slots as configured; accounts left out of the mapping are skipped.
--- @param accounts table account name to balance
local function slots(accounts)
    local out = { cash = 0, bank = 0, crypto = 0 }
    for name, amount in pairs(accounts) do
        local slot = cfg.esx.accounts[tostring(name):lower()]
        amount = tonumber(amount)
        if SLOTS[slot] and amount then out[slot] = out[slot] + amount end
    end
    return out
end

--- Page: runs one keyset page and maps each row; returns the rows, the cursor for the next page and the row count.
local function page(sql, params, key, map)
    local rows = db.query(sql, params)
    if type(rows) ~= 'table' then return nil end
    local out = {}
    for i = 1, #rows do out[i] = map(rows[i]) end
    return out, rows[#rows] and rows[#rows][key], #rows
end

-- Changed rows: users carries a timestamp that updates with the row only on some setups, so it is checked once per run.
local changed -- changed: quoted column name when changed rows can be found, false when not, nil until checked

local function checkChanged()
    if changed ~= nil then return end
    local column = common.sqlName(cfg.esx.changedColumn)
    if not column then changed = false return end
    local extra, err = db.scalar(
        'SELECT EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?',
        { cfg.esx.tables.characters, cfg.esx.changedColumn })
    if err then return end -- error: asked again on the next run
    changed = type(extra) == 'string' and extra:lower():find('on update', 1, true) ~= nil and column or false
end

local function changedFilter(since)
    return since and (changed .. ' >= FROM_UNIXTIME(?) AND') or ''
end

local function count(since)
    local t = tbl('characters')
    if not t then return nil end
    return db.scalar('SELECT COUNT(*) FROM ' .. t .. (since and (' WHERE ' .. changed .. ' >= FROM_UNIXTIME(?)') or ''),
        since and { since } or {})
end

-- Money: balances from the users table.
local money = {}

function money.init()
    checkChanged()
    money.delta = changed ~= false and changed ~= nil
end

money.count = count

function money.page(since, cursor, per)
    local t = tbl('characters')
    if not t then return nil end
    local params = since and { since } or {}
    params[#params + 1] = cursor or ''
    return page(('SELECT identifier, accounts FROM %s WHERE %s identifier > ? ORDER BY identifier LIMIT %d'):format(
        t, changedFilter(since), per), params, 'identifier', function(r)
        local ok, accounts = pcall(json.decode, r.accounts or '')
        local s = slots(ok and type(accounts) == 'table' and accounts or {})
        return { r.identifier, s.cash, s.bank, s.crypto }
    end)
end

-- Census: player inventories; ESX's own inventory is a { name = count } table, which becomes a list.
local players = { kind = 'player', order = 10 }

players.count = count

function players.page(since, cursor, per)
    local t = tbl('characters')
    if not t then return nil end
    local params = since and { since } or {}
    params[#params + 1] = cursor or ''
    return page(('SELECT identifier, inventory FROM %s WHERE %s identifier > ? ORDER BY identifier LIMIT %d'):format(
        t, changedFilter(since), per), params, 'identifier', function(r)
        return { r.identifier, AtlasLib.inventory.census(r.inventory, json) }
    end)
end

-- Vehicles: owner, model hash and plate hash per owned vehicle; the plate is the table's key.
local vehicles = { owned = {} }

--- Model: the model hash inside a vehicle's saved properties; a model name is hashed, a missing one is 0.
local function modelOf(props)
    if type(props) ~= 'string' then return 0 end
    local n = props:match('"model"%s*:%s*(-?%d+)')
    if n then return common.u32(tonumber(n)) end
    local name = props:match('"model"%s*:%s*"([^"]+)"')
    if name then return common.u32(tonumber(name) or GetHashKey(name)) end
    return 0
end

function vehicles.owned.count()
    local t = tbl('vehicles')
    return t and db.scalar(('SELECT COUNT(*) FROM %s WHERE owner IS NOT NULL'):format(t))
end

function vehicles.owned.page(cursor, per)
    local t = tbl('vehicles')
    if not t then return nil end
    return page(('SELECT owner, plate, vehicle FROM %s WHERE owner IS NOT NULL AND plate > ? ORDER BY plate LIMIT %d'):format(t, per),
        { cursor or '' }, 'plate', function(r)
            local plate = common.plate(r.plate)
            return { r.owner, modelOf(r.vehicle), plate and common.u32(GetHashKey(plate)) or 0 }
        end)
end

-- Shared object: fetched once and kept, since each fetch copies every ESX function across resources.
local sharedObject -- sharedObject: ESX's table of helpers, nil until fetched or after es_extended stops

--- Shared object: ESX's own table of helpers, nil while es_extended is not ready.
local function shared()
    if sharedObject then return sharedObject end
    local ok, esx = pcall(function() return exports.es_extended:getSharedObject() end)
    sharedObject = ok and type(esx) == 'table' and esx or nil
    return sharedObject
end

AddEventHandler('onResourceStop', function(res)
    if res == 'es_extended' then sharedObject = nil end
end)

Atlas.frameworkData.esx = {
    slots = slots, -- slots: used by the adapter to turn live account balances into money slots
    shared = shared, -- shared: the cached ESX object, also used by the adapter
    money = money,
    census = function()
        checkChanged()
        players.delta = changed ~= false and changed ~= nil
        return { players }
    end,
    vehicles = vehicles,
    -- Groups: ESX has jobs only
    groups = function()
        local jobs = {}
        local esx = shared()
        local ok, list = pcall(function() return esx and esx.GetJobs() end)
        if ok and type(list) == 'table' then for name in pairs(list) do jobs[name] = true end end
        return jobs, {}
    end,
}

-- Places: garages, hospitals, police stations and shops from the official ESX resources.
Atlas.registerSource('places', {
    name = 'esx_garage',
    resources = { 'esx_garage' },
    read = function(add)
        local _, env = Atlas.loadConfig('esx_garage', 'config.lua')
        local conf = env and rawget(env, 'Config')
        if type(conf) ~= 'table' or type(conf.Garages) ~= 'table' then return end
        -- Layouts: a list with label and entryPoint since 1.16, a table keyed by name with EntryPoint before
        for key, g in pairs(conf.Garages) do
            if type(g) == 'table' then add(g.label or g.id or tostring(key), 'garage', g.entryPoint or g.EntryPoint) end
        end
    end,
})

Atlas.registerSource('places', {
    name = 'esx_ambulancejob',
    resources = { 'esx_ambulancejob' },
    read = function(add)
        local _, env = Atlas.loadConfig('esx_ambulancejob', 'config.lua')
        local conf = env and rawget(env, 'Config')
        if type(conf) ~= 'table' or type(conf.Hospitals) ~= 'table' then return end
        for id, h in pairs(conf.Hospitals) do
            if type(h) == 'table' and type(h.Blip) == 'table' then add(tostring(id), 'hospital', h.Blip.coords) end
        end
    end,
})

Atlas.registerSource('places', {
    name = 'esx_policejob',
    resources = { 'esx_policejob' },
    read = function(add)
        local _, env = Atlas.loadConfig('esx_policejob', 'config.lua')
        local conf = env and rawget(env, 'Config')
        if type(conf) ~= 'table' or type(conf.PoliceStations) ~= 'table' then return end
        for id, st in pairs(conf.PoliceStations) do
            if type(st) == 'table' and type(st.Blip) == 'table' then add(tostring(id), 'police', st.Blip.Coords) end
        end
    end,
})

--- Shop zones: esx_shops defines Config in one file and fills it in another, so both run against one seeded table.
--- Older versions keep the same zones in a single config.lua.
local function shopZones()
    local conf = {}
    Atlas.loadConfig('esx_shops', 'shared/config/main.lua', { Config = conf })
    Atlas.loadConfig('esx_shops', 'shared/config/shops.lua', { Config = conf })
    if type(conf.Zones) ~= 'table' then
        local _, env = Atlas.loadConfig('esx_shops', 'config.lua')
        conf = env and rawget(env, 'Config') or {}
    end
    return type(conf.Zones) == 'table' and conf.Zones or nil
end

Atlas.registerSource('places', {
    name = 'esx_shops',
    resources = { 'esx_shops' },
    read = function(add)
        local zones = shopZones()
        if not zones then return end
        for name, zone in pairs(zones) do
            if type(zone) == 'table' and type(zone.Pos) == 'table' then
                for _, pos in sandbox.items(zone.Pos) do add(tostring(name), 'shop', pos) end
            end
        end
    end,
})

-- Prices: vehicles from the vehicles table and items from the shop zones.
Atlas.registerSource('prices', {
    name = 'esx_vehicles',
    resources = { 'es_extended' },
    read = function(emit)
        local t = tbl('vehiclePrices')
        if not t or not db.available() then return end
        local rows = db.query(('SELECT model, name, price, category FROM %s ORDER BY model LIMIT 5000'):format(t))
        if type(rows) ~= 'table' then return end
        local entries = {}
        for i = 1, #rows do
            local r = rows[i]
            if tonumber(r.price) and r.model then
                entries[#entries + 1] = { tostring(r.model):lower(), tostring(r.name or r.model), tonumber(r.price), '', tostring(r.category or '') }
            end
        end
        emit('vehicle', entries)
    end,
})

Atlas.registerSource('prices', {
    name = 'esx_shops',
    resources = { 'esx_shops' },
    read = function(emit)
        local zones = shopZones()
        if not zones then return end
        local entries, seen = {}, {}
        for zone, def in pairs(zones) do
            if type(def) == 'table' and type(def.Items) == 'table' then
                for _, it in sandbox.items(def.Items) do
                    if type(it) == 'table' and type(it.name) == 'string' and tonumber(it.price) then
                        local key = it.name .. '@' .. zone
                        if not seen[key] then
                            seen[key] = true
                            entries[#entries + 1] = { it.name, '', tonumber(it.price), tostring(zone) }
                        end
                    end
                end
            end
        end
        emit('item', entries)
    end,
})

-- Accounts: society accounts of esx_addonaccount, which have no owner; a society named after a job counts as that job's.
Atlas.registerSource('accounts', {
    name = 'esx_addonaccount',
    resources = { 'esx_addonaccount' },
    read = function()
        local t = tbl('societyAccounts')
        if not t then return nil, 'invalid table name' end
        local rows, err = db.query(('SELECT account_name, money FROM %s WHERE owner IS NULL'):format(t))
        if type(rows) ~= 'table' then return nil, err end
        local jobs = Atlas.groups()
        local out = {}
        for i = 1, #rows do
            local r = rows[i]
            local id = tostring(r.account_name)
            local job = id:match('^society_(.+)$')
            out[#out + 1] = { id, (job and jobs and jobs[job]) and 'job' or 'business', tonumber(r.money) or 0 }
        end
        return out
    end,
})
