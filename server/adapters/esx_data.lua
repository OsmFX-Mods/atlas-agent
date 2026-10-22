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

--- Slots: sums account balances by money type as configured; accounts left out of the mapping are skipped.
--- Cash, bank and crypto are the types money snapshots carry; any other type name is reported in money changes only.
--- @param accounts table account name to balance
local function slots(accounts)
    local out = { cash = 0, bank = 0, crypto = 0 }
    for name, amount in pairs(accounts) do
        local kind = cfg.esx.accounts[tostring(name):lower()]
        amount = tonumber(amount)
        if type(kind) == 'string' and kind ~= '' and amount then out[kind] = (out[kind] or 0) + amount end
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

-- Columns: what the users table offers differs between setups, so it is looked up once and kept.
local columns -- columns: { changed, created = quoted column name or false, names = true when first and last name columns exist }, nil until read

--- Columns: the users columns Atlas can use; nil after a database error, so the next call asks again.
local function checkColumns()
    if columns then return columns end
    local rows = db.query('SELECT COLUMN_NAME AS c, EXTRA AS e FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?',
        { cfg.esx.tables.characters })
    if type(rows) ~= 'table' then return nil end
    local extra = {} -- extra: lower-case column name to its lower-case EXTRA text
    for i = 1, #rows do
        if type(rows[i].c) == 'string' then extra[rows[i].c:lower()] = type(rows[i].e) == 'string' and rows[i].e:lower() or '' end
    end
    --- Column: the configured column when it exists and updates with the row (or never does, when onUpdate is false).
    local function column(name, onUpdate)
        local quoted = common.sqlName(name)
        local e = quoted and extra[name:lower()]
        if not e then return false end
        return (e:find('on update', 1, true) ~= nil) == onUpdate and quoted or false
    end
    columns = {
        changed = column(cfg.esx.changedColumn, true),
        created = column(cfg.esx.createdColumn, false),
        names = extra.firstname ~= nil and extra.lastname ~= nil,
    }
    Atlas.log('esx characters are keyed by %s', columns.created and 'identifier and creation time'
        or 'identifier only (users has no fixed creation time column)')
    return columns
end

-- Character keys: ESX names a character after its slot (char1:<license>) and gives the name to the next character made in that slot
-- once it is deleted. Characters created from KEYS_FROM on are keyed by identifier and creation time, so a new character never takes
-- over the history of a deleted one; older characters keep the plain identifier their history was recorded under.
local KEYS_FROM = 1761177600 -- KEYS_FROM: 2026-10-23 00:00 UTC, the first creation time that gets a timed key

--- Key: SQL for a character's key; prefix names the users table in a join.
local function keySql(prefix)
    prefix = prefix or ''
    local id = prefix .. 'identifier'
    local created = columns and columns.created
    if not created then return id end
    local at = prefix .. created
    return ("CASE WHEN %s >= FROM_UNIXTIME(%d) THEN CONCAT(%s, '#', FLOOR(UNIX_TIMESTAMP(%s))) ELSE %s END"):format(at, KEYS_FROM, id, at, id)
end

local function changedFilter(since)
    return since and (columns.changed .. ' >= FROM_UNIXTIME(?) AND') or ''
end

local function count(since)
    local t = tbl('characters')
    if not t then return nil end
    return db.scalar('SELECT COUNT(*) FROM ' .. t .. (since and (' WHERE ' .. columns.changed .. ' >= FROM_UNIXTIME(?)') or ''),
        since and { since } or {})
end

local keys = {}

--- Timed: whether characters get timed keys (true), plain identifiers (false), or nil while the database cannot tell.
--- Known only: answers from what was already read, without a query, so an event handler never waits on the database.
function keys.timed(knownOnly)
    local c = knownOnly and columns or checkColumns()
    if not c then return nil end
    return c.created ~= false
end

--- Current: the key of the character in an identifier's slot now; false when the slot is empty, nil after a database error.
function keys.current(identifier)
    local t = tbl('characters')
    if not t or not checkColumns() then return nil end
    local key, err = db.scalar(('SELECT %s FROM %s WHERE identifier = ?'):format(keySql(), t), { identifier })
    if err then return nil end
    return key ~= nil and tostring(key) or false
end

--- Key: the key of one character; the plain identifier when keys are not timed or the row is missing, nil after a database error.
function keys.of(identifier)
    local timed = keys.timed()
    if not timed then return timed == false and identifier or nil end
    local key = keys.current(identifier)
    if key == nil then return nil end
    return key or identifier
end

--- Account: the characters of one account as identifier to { key, name }; nil after a database error.
--- @param license string the account's identifier without its type, as ESX stores it after the slot prefix
function keys.account(license)
    if type(license) ~= 'string' or not license:find('^[%w]+$') then return nil end
    local c = checkColumns()
    local t = tbl('characters')
    if not c or not t then return nil end
    local name = c.names and ", CONCAT_WS(' ', firstname, lastname) AS n" or ''
    local rows = db.query(('SELECT identifier, %s AS k%s FROM %s WHERE identifier = ? OR identifier LIKE ?'):format(keySql(), name, t),
        { license, '%:' .. license })
    if type(rows) ~= 'table' then return nil end
    local out = {}
    for i = 1, #rows do
        local r = rows[i]
        if type(r.identifier) == 'string' then
            out[r.identifier] = { key = tostring(r.k or r.identifier), name = type(r.n) == 'string' and r.n:match('^%s*(.-)%s*$') or '' }
        end
    end
    return out
end

-- Money: balances from the users table.
local money = {}

function money.init()
    local c = checkColumns()
    money.delta = c ~= nil and c.changed ~= false
end

money.count = count

function money.page(since, cursor, per)
    local t = tbl('characters')
    if not t or not checkColumns() then return nil end
    local params = since and { since } or {}
    params[#params + 1] = cursor or ''
    return page(('SELECT identifier, %s AS k, accounts FROM %s WHERE %s identifier > ? ORDER BY identifier LIMIT %d'):format(
        keySql(), t, changedFilter(since), per), params, 'identifier', function(r)
        local ok, accounts = pcall(json.decode, r.accounts or '')
        local s = slots(ok and type(accounts) == 'table' and accounts or {})
        return { r.k, s.cash, s.bank, s.crypto }
    end)
end

-- Census: player inventories; ESX's own inventory is a { name = count } table, which becomes a list.
local players = { kind = 'player', order = 10 }

players.count = count

function players.page(since, cursor, per)
    local t = tbl('characters')
    if not t or not checkColumns() then return nil end
    local params = since and { since } or {}
    params[#params + 1] = cursor or ''
    return page(('SELECT identifier, %s AS k, inventory FROM %s WHERE %s identifier > ? ORDER BY identifier LIMIT %d'):format(
        keySql(), t, changedFilter(since), per), params, 'identifier', function(r)
        return { r.k, AtlasLib.inventory.census(r.inventory, json) }
    end)
end

-- Vehicles: owner, model hash and plate hash per owned vehicle; the plate is the table's key.
-- Owner: a character's key when keys are timed, read through the users table; owners that are not characters stay as they are.
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
    local t, users = tbl('vehicles'), tbl('characters')
    local c = checkColumns()
    if not t or not users or not c then return nil end
    local sql
    if c.created then
        sql = ('SELECT v.plate, v.vehicle, COALESCE(%s, v.owner) AS k FROM %s v LEFT JOIN %s u ON u.identifier = v.owner WHERE v.owner IS NOT NULL AND v.plate > ? ORDER BY v.plate LIMIT %d'):format(
            keySql('u.'), t, users, per)
    else
        sql = ('SELECT plate, vehicle, owner AS k FROM %s WHERE owner IS NOT NULL AND plate > ? ORDER BY plate LIMIT %d'):format(t, per)
    end
    return page(sql, { cursor or '' }, 'plate', function(r)
        local plate = common.plate(r.plate)
        return { r.k, modelOf(r.vehicle), plate and common.u32(GetHashKey(plate)) or 0 }
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
    slots = slots, -- slots: used by the adapter to turn live account balances into money types
    shared = shared, -- shared: the cached ESX object, also used by the adapter
    keys = keys, -- keys: character keys, used by the adapter for live characters and deletions
    money = money,
    census = function()
        local c = checkColumns()
        players.delta = c ~= nil and c.changed ~= false
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
