-- QBCore data: the database readers and the places, prices and accounts that come with qb resources.
-- Tables and money types: names come from AtlasConfig.qbcore, so renamed tables and custom money types keep working.
-- Inventories: qb-inventory keeps trunks, gloveboxes and stashes in one table (2024 on) or in three older tables.

local cfg = AtlasConfig
local common = AtlasLib.common
local sandbox = AtlasLib.sandbox
local db = Atlas.db

--- Table: a configured table name as a quoted identifier, nil with a warning when it is not a valid name.
local function tbl(key)
    local name = common.sqlName(cfg.qbcore.tables[key])
    if not name then Atlas.warn('config: qbcore.tables.%s is not a valid table name', key) end
    return name
end

--- Money type: the type a QBCore money type counts as; types the config leaves out keep their own name.
local function moneyType(name)
    name = tostring(name):lower()
    local mapped = cfg.qbcore.moneyTypes[name]
    return type(mapped) == 'string' and mapped ~= '' and mapped or name
end

--- Balances: a QBCore money table by money type; cash, bank and crypto are always present, as money snapshots carry them.
local function balances(money)
    local out = { cash = 0, bank = 0, crypto = 0 }
    for name, amount in pairs(type(money) == 'table' and money or {}) do
        amount = tonumber(amount)
        if amount then
            local kind = moneyType(name)
            out[kind] = (out[kind] or 0) + amount
        end
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

-- Tables: which tables and columns exist differs between qb-core and qb-inventory versions, so it is looked up and kept.
local present = {} -- present[name]: table name to a set of lower-case column names with their EXTRA text, false when the table is missing

--- Columns: the columns of a table as lower-case name to lower-case EXTRA; false when the table is missing, nil after a database error.
local function columnsOf(name)
    if present[name] ~= nil then return present[name] end
    local rows = db.query('SELECT COLUMN_NAME AS c, EXTRA AS e FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { name })
    if type(rows) ~= 'table' then return nil end
    local cols = false
    for i = 1, #rows do
        if type(rows[i].c) == 'string' then
            cols = cols or {}
            cols[rows[i].c:lower()] = type(rows[i].e) == 'string' and rows[i].e:lower() or ''
        end
    end
    present[name] = cols
    return cols
end

--- Changed: the quoted changed column of the characters table when it updates with the row, false when not, nil after an error.
local function changedColumn()
    local cols = columnsOf(cfg.qbcore.tables.characters)
    if cols == nil then return nil end
    local name = cfg.qbcore.changedColumn
    local quoted = common.sqlName(name)
    local extra = cols and quoted and cols[name:lower()]
    return extra and extra:find('on update', 1, true) and quoted or false
end

local function countChars(since, changed)
    local t = tbl('characters')
    if not t then return nil end
    return db.scalar('SELECT COUNT(*) FROM ' .. t .. (since and (' WHERE ' .. changed .. ' >= FROM_UNIXTIME(?)') or ''), since and { since } or {})
end

local function charPage(column, since, cursor, per, changed, map)
    local t = tbl('characters')
    if not t then return nil end
    local params = since and { since } or {}
    params[#params + 1] = cursor or ''
    return page(('SELECT citizenid, %s AS d FROM %s WHERE %s citizenid > ? ORDER BY citizenid LIMIT %d'):format(
        column, t, since and (changed .. ' >= FROM_UNIXTIME(?) AND') or '', per), params, 'citizenid', map)
end

-- Money: balances from the money column of the players table, decoded here since money types are configurable.
local money = {}
local moneyChanged -- moneyChanged: the changed column found by init, false when there is none

function money.init()
    moneyChanged = changedColumn()
    money.delta = moneyChanged and true or false
end

function money.count(since) return countChars(since, moneyChanged) end

function money.page(since, cursor, per)
    return charPage('money', since, cursor, per, moneyChanged, function(r)
        local ok, m = pcall(json.decode, r.d or '')
        local b = balances(ok and m or nil)
        return { r.citizenid, b.cash, b.bank, b.crypto }
    end)
end

-- Census: player inventories from the players table, in qb-inventory's list form.
local players = { kind = 'player', order = 10 }
local playersChanged

function players.count(since) return countChars(since, playersChanged) end

function players.page(since, cursor, per)
    return charPage('inventory', since, cursor, per, playersChanged, function(r)
        return { r.citizenid, AtlasLib.inventory.census(r.d, json) }
    end)
end

-- Vehicles: owner, model hash and plate hash per owned vehicle, from the player_vehicles table of qb-vehicleshop.
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

-- Core object: fetched once and kept, since each fetch copies every shared table across resources; refreshed when qb-core changes it.
local coreObject -- coreObject: qb-core's shared object, nil until fetched

--- Core: qb-core's shared object, nil while qb-core is not ready.
local function core()
    if coreObject then return coreObject end
    local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
    coreObject = ok and type(obj) == 'table' and obj or nil
    return coreObject
end

AddEventHandler('QBCore:Server:UpdateObject', function() coreObject = nil end)
AddEventHandler('onResourceStop', function(res)
    if res == 'qb-core' then coreObject = nil end
end)

--- Holder: the kind and id a qb-inventory inventory name stands for; plates are hashed, never sent.
--- @return string kind, string id
local function holder(name)
    name = tostring(name)
    local kind, plate = name:match('^(%a+)%-(.+)$')
    if kind == 'trunk' or kind == 'glovebox' then
        plate = common.plate(plate)
        return kind, plate and tostring(common.u32(GetHashKey(plate))) or '0'
    end
    return 'stash', name
end

-- Census: qb-inventory trunks, gloveboxes and stashes; none of these tables records a change time, so they are always sent in full.
-- Layouts: one inventories table keyed by name (trunk-PLATE, glovebox-PLATE, stash name) from 2024 on, or the older
-- trunkitems, gloveboxitems and stashitems tables, which forks such as ps-inventory still use; a missing table counts as empty.

--- Storage: a census kind read from whichever layout the database has; a missing table counts as empty.
local function storage(kind, order, legacyKey, legacyColumn)
    local function source()
        local current = cfg.qbcore.tables.inventories
        local cols = columnsOf(current)
        if cols == nil then return nil end
        if cols then
            local filter = kind == 'stash' and "identifier NOT LIKE 'trunk-%' AND identifier NOT LIKE 'glovebox-%'"
                or ("identifier LIKE '" .. kind .. "-%'")
            return { t = common.sqlName(current), key = 'identifier', filter = filter }
        end
        local legacy = cfg.qbcore.tables[legacyKey]
        local lcols = columnsOf(legacy)
        if lcols == nil then return nil end
        if not lcols then return false end
        return { t = common.sqlName(legacy), key = legacyColumn, filter = '1 = 1', legacy = true }
    end
    return {
        kind = kind, order = order,
        count = function()
            local s = source()
            if not s or not s.t then return 0 end
            return db.scalar(('SELECT COUNT(*) FROM %s WHERE %s'):format(s.t, s.filter))
        end,
        page = function(_, cursor, per)
            local s = source()
            if s == nil then return nil end
            if not s or not s.t then return {}, nil, 0 end
            return page(('SELECT %s AS k, items FROM %s WHERE %s AND %s > ? ORDER BY %s LIMIT %d'):format(
                s.key, s.t, s.filter, s.key, s.key, per), { cursor or '' }, 'k', function(r)
                local name = s.legacy and kind ~= 'stash' and (kind .. '-' .. tostring(r.k)) or r.k
                local _, id = holder(name)
                return { id, AtlasLib.inventory.census(r.items, json) }
            end)
        end,
    }
end

Atlas.frameworkData.qbcore = {
    moneyType = moneyType, -- moneyType: used by the adapter to name live money changes
    balances = balances,   -- balances: used by the adapter to turn PlayerData.money into money types
    core = core,           -- core: the cached qb-core object, also used by the adapter
    holder = holder,       -- holder: used by the qb-inventory adapter, so live item events and the census name holders alike
    money = money,
    census = function()
        playersChanged = changedColumn()
        players.delta = playersChanged and true or false
        return { players, storage('stash', 20, 'stashItems', 'stash'), storage('trunk', 30, 'trunkItems', 'plate'),
            storage('glovebox', 40, 'gloveboxItems', 'plate') }
    end,
    vehicles = vehicles,
    -- Groups: job and gang names, used to classify bank accounts
    groups = function()
        local jobs, gangs = {}, {}
        local obj = core()
        local shared = obj and type(obj.Shared) == 'table' and obj.Shared or {}
        for name in pairs(type(shared.Jobs) == 'table' and shared.Jobs or {}) do jobs[name] = true end
        for name in pairs(type(shared.Gangs) == 'table' and shared.Gangs or {}) do
            if name ~= 'none' then gangs[name] = true end
        end
        return jobs, gangs
    end,
}

--- Lang: a qb resource's English phrases, so configs that name places with Lang:t load with readable names.
local function qbLang(res)
    local phrases = {}
    local locale = {
        new = function(_, opts)
            if type(opts) == 'table' and type(opts.phrases) == 'table' then phrases = opts.phrases end
            return {}
        end,
    }
    -- Lang is false so the file's `Lang = Lang or Locale:new(...)` reaches Locale
    Atlas.loadConfig(res, 'locales/en.lua', { Lang = false, Locale = locale })
    return {
        t = function(_, key)
            local v = phrases
            for part in tostring(key):gmatch('[^%.]+') do v = type(v) == 'table' and v[part] or nil end
            return type(v) == 'string' and v or tostring(key)
        end,
    }
end

--- Config: the Config table of a qb resource's config.lua, read with its English phrases.
local function qbConfig(res)
    local _, env = Atlas.loadConfig(res, 'config.lua', { Lang = qbLang(res) })
    return env and rawget(env, 'Config'), env
end
Atlas.frameworkData.qbcore.config = qbConfig -- config: also used by the qb-ambulancejob adapter for hospital names and the bill

--- Positions: a config position, which older resources give as a list of positions.
local function positions(v)
    if type(v) == 'table' and v.x == nil and v[1] ~= nil then return sandbox.items(v) end
    local done = false
    return function()
        if done then return end
        done = true
        return 1, v
    end
end

-- Places: garages, hospitals, police stations and shops from the official qb resources.
Atlas.registerSource('places', {
    name = 'qb-garages',
    resources = { 'qb-garages' },
    read = function(add)
        local conf, env = qbConfig('qb-garages')
        -- Layouts: Config.Garages in current versions, a global Garages table in older ones
        local garages = type(conf) == 'table' and type(conf.Garages) == 'table' and conf.Garages or (env and rawget(env, 'Garages'))
        if type(garages) ~= 'table' then return end
        for id, g in pairs(garages) do
            if type(g) == 'table' then add(type(g.label) == 'string' and g.label or tostring(id), 'garage', g.takeVehicle or g.putVehicle) end
        end
    end,
})

Atlas.registerSource('places', {
    name = 'qb-ambulancejob',
    resources = { 'qb-ambulancejob' },
    read = function(add)
        local conf = qbConfig('qb-ambulancejob')
        local hospitals = type(conf) == 'table' and type(conf.Locations) == 'table' and conf.Locations.hospital
        if type(hospitals) ~= 'table' then return end
        for i, h in sandbox.items(hospitals) do
            if type(h) == 'table' then add(type(h.name) == 'string' and h.name or tostring(i), 'hospital', h.location) end
        end
    end,
})

Atlas.registerSource('places', {
    name = 'qb-policejob',
    resources = { 'qb-policejob' },
    read = function(add)
        local conf = qbConfig('qb-policejob')
        local stations = type(conf) == 'table' and type(conf.Locations) == 'table' and conf.Locations.stations
        if type(stations) ~= 'table' then return end
        for _, st in sandbox.items(stations) do
            if type(st) == 'table' then add(st.label, 'police', st.coords) end
        end
    end,
})

--- Shops: the shop locations of qb-shops, keyed by shop name.
local function qbShops()
    local conf = qbConfig('qb-shops')
    return type(conf) == 'table' and type(conf.Locations) == 'table' and conf.Locations or nil
end

Atlas.registerSource('places', {
    name = 'qb-shops',
    resources = { 'qb-shops' },
    read = function(add)
        local shops = qbShops()
        if not shops then return end
        for name, shop in pairs(shops) do
            if type(shop) == 'table' then
                for _, pos in positions(shop.coords) do add(type(shop.label) == 'string' and shop.label or tostring(name), 'shop', pos) end
            end
        end
    end,
})

-- Prices: vehicles from qb-core's shared vehicles and items from qb-shops.
Atlas.registerSource('prices', {
    name = 'qbcore_vehicles',
    resources = { 'qb-core' },
    read = function(emit)
        -- Qbox: qbx_core also answers to qb-core, and its own prices source covers it
        if not (Atlas.framework and Atlas.framework.name == 'qbcore') then return end
        local obj = core()
        local list = obj and type(obj.Shared) == 'table' and obj.Shared.Vehicles
        if type(list) ~= 'table' then return end
        local entries = {}
        for model, v in pairs(list) do
            if type(v) == 'table' and tonumber(v.price) then
                local label = ((type(v.brand) == 'string' and v.brand or '') .. ' ' .. (type(v.name) == 'string' and v.name or tostring(model))):gsub('^%s+', '')
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
    name = 'qb-shops',
    resources = { 'qb-shops' },
    read = function(emit)
        local shops = qbShops()
        if not shops then return end
        local entries, seen = {}, {}
        for name, shop in pairs(shops) do
            if type(shop) == 'table' and type(shop.products) == 'table' then
                for _, it in pairs(shop.products) do
                    if type(it) == 'table' and type(it.name) == 'string' and tonumber(it.price) then
                        local key = it.name .. '@' .. tostring(name)
                        if not seen[key] then
                            seen[key] = true
                            entries[#entries + 1] = { it.name, '', tonumber(it.price), tostring(name) }
                        end
                    end
                end
            end
        end
        table.sort(entries, function(a, b) return a[1] .. a[4] < b[1] .. b[4] end)
        emit('item', entries)
    end,
})

-- Accounts: job, gang and shared accounts of qb-banking; servers on qb-management before it moved to qb-banking keep job
-- and gang funds in management_funds instead, which is read only while qb-banking is not running.
local KINDS = { job = 'job', gang = 'gang', shared = 'shared' }

Atlas.registerSource('accounts', {
    name = 'qb-banking',
    resources = { 'qb-banking' },
    read = function()
        local t = tbl('bankAccounts')
        if not t then return nil, 'invalid table name' end
        local rows, err = db.query(('SELECT account_name, account_balance, account_type FROM %s'):format(t))
        if type(rows) ~= 'table' then return nil, err end
        local out = {}
        for i = 1, #rows do
            local r = rows[i]
            if r.account_name then
                out[#out + 1] = { tostring(r.account_name), KINDS[r.account_type] or 'business', tonumber(r.account_balance) or 0 }
            end
        end
        return out
    end,
})

Atlas.registerSource('accounts', {
    name = 'qb-management',
    resources = { 'qb-management' },
    read = function()
        if GetResourceState('qb-banking') == 'started' then return {} end
        local t = tbl('managementFunds')
        if not t then return nil, 'invalid table name' end
        local cols = columnsOf(cfg.qbcore.tables.managementFunds)
        if cols == nil then return nil, 'database error' end
        if not cols then return {} end
        local rows, err = db.query(('SELECT job_name, amount, type FROM %s'):format(t))
        if type(rows) ~= 'table' then return nil, err end
        local out = {}
        for i = 1, #rows do
            local r = rows[i]
            if r.job_name then
                out[#out + 1] = { tostring(r.job_name), r.type == 'gang' and 'gang' or 'job', tonumber(r.amount) or 0 }
            end
        end
        return out
    end,
})
