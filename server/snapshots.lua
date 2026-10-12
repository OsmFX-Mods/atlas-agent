-- Snapshots: reads game data through oxmysql and emits it as events; the daemon never holds database credentials.
-- Paging: keyset pages with a Wait between them; delta runs use the database clock, so agent clock skew cannot skip rows.

local cfg = AtlasConfig
local common = AtlasLib.common
local sandbox = AtlasLib.sandbox
local floor, ceil = math.floor, math.ceil
local db = Atlas.db

local busy = false
local runCounter = 0
local moneySince      -- moneySince: database clock (s) at the start of the previous money run
local lastMoneyAt, lastAccountsAt = 0, 0
local catalogDone = false

-- Watermark: the database second before a run started, so rows stamped inside that second are read again, never skipped
local function watermark(dbNow) return floor(dbNow) - 1 end

local function kvpNum(key)
    return tonumber(GetResourceKvpString(key) or '')
end

local function kvpSet(key, v)
    SetResourceKvp(key, tostring(v))
end

local function newId(prefix)
    runCounter = runCounter + 1
    return ('%s-%s%d'):format(Atlas.boot, prefix, runCounter)
end

local function toMs(sec)
    return sec and floor(sec * 1000) or nil
end

local function pagesFor(count, extra, per)
    return math.max(1, ceil(((tonumber(count) or 0) + (extra or 0)) / per))
end

-- Money snapshot: balances of changed characters; online players use live balances.
local MONEY_SQL = [[SELECT citizenid,
    COALESCE(JSON_EXTRACT(money, '$.cash') + 0, 0) AS cash,
    COALESCE(JSON_EXTRACT(money, '$.bank') + 0, 0) AS bank,
    COALESCE(JSON_EXTRACT(money, '$.crypto') + 0, 0) AS crypto
    FROM players WHERE %s citizenid > ? ORDER BY citizenid LIMIT %d]]

local function moneySnapshot(mode)
    local dbNow, err = db.now()
    if not dbNow then return Atlas.warn('money snapshot skipped: %s', tostring(err)) end
    local since = (mode == 'delta') and moneySince or nil
    if mode == 'delta' and not since then mode = 'full' end

    local filter, params = '', {}
    if mode == 'delta' then filter, params = 'last_updated >= FROM_UNIXTIME(?) AND', { since } end

    local count = db.scalar('SELECT COUNT(*) FROM players' .. (mode == 'delta' and ' WHERE last_updated >= FROM_UNIXTIME(?)' or ''), params)

    -- Online players: always sent with live balances, since the database lags until qbx saves
    local online, onlineN = {}, 0
    for char, m in pairs(Atlas.onlineBalances and Atlas.onlineBalances() or {}) do
        online[char] = { m.cash or 0, m.bank or 0, m.crypto or 0 }
        onlineN = onlineN + 1
    end

    local per = cfg.moneyPageRows
    local sql = MONEY_SQL:format(filter, per)
    local pages = pagesFor(count, onlineN, per)
    local id = newId('m')
    local page, last, emitted = 0, '', {}

    while true do
        local q = { table.unpack(params) }
        q[#q + 1] = last
        local rows = db.query(sql, q)
        if type(rows) ~= 'table' then return Atlas.warn('money snapshot page failed') end -- watermark stays, so the next run is full
        local out = {}
        for i = 1, #rows do
            local r = rows[i]
            local live = online[r.citizenid]
            if live then
                out[i] = { r.citizenid, live[1], live[2], live[3] }
                emitted[r.citizenid] = true
            else
                out[i] = { r.citizenid, tonumber(r.cash) or 0, tonumber(r.bank) or 0, tonumber(r.crypto) or 0 }
            end
            last = r.citizenid
        end
        local done = #rows < per
        -- Leftovers: online characters the query did not return go on the last page
        if done then
            for char, live in pairs(online) do
                if not emitted[char] then out[#out + 1] = { char, live[1], live[2], live[3] } end
            end
        end
        page = page + 1
        if page > pages then pages = page end
        Atlas.emit('money.snapshot', {
            snapshot_id = id, mode = mode, since_ts = toMs(since),
            rows = out, page = page, pages = pages, final = done or nil,
        })
        if done then break end
        Wait(100)
    end
    moneySince = watermark(dbNow)
    if mode == 'full' then kvpSet('atlas:money_full_at', os.time()) end
    Atlas.debug('money snapshot %s: %d pages', mode, page)
end

-- Accounts snapshot: Renewed-Banking bank_accounts_new.
local function accountsSnapshot()
    if not Atlas.accountsRows then return end
    local rows, err = Atlas.accountsRows()
    if not rows then return Atlas.debug('accounts snapshot skipped: %s', tostring(err)) end
    Atlas.emit('accounts.snapshot', { snapshot_id = newId('a'), rows = rows })
end

-- Census: items and vehicles.
local function censusPages(id, mode, since, kind, countSql, countParams, pageFn)
    local per = cfg.censusPageRows
    local pages = pagesFor(db.scalar(countSql, countParams), 0, per)
    local page, cursor = 0, nil
    while true do
        local rows, nextCursor, got = pageFn(cursor, per)
        if not rows then Atlas.warn('census %s page failed', kind) return false end
        page = page + 1
        if page > pages then pages = page end
        local done = got < per
        Atlas.emit('items.census', {
            census_id = id, mode = mode, since_ts = toMs(since), holder_kind = kind,
            rows = rows, page = page, pages = pages, final = done or nil,
        })
        if done then return true end
        cursor = nextCursor
        Wait(200)
    end
end

local function itemsCensus(mode)
    if GetResourceState('ox_inventory') ~= 'started' then return end
    local dbNow = db.now()
    if not dbNow then return end
    local since = (mode == 'delta') and kvpNum('atlas:census_since') or nil
    if mode == 'delta' and not since then mode = 'full' end
    local delta = mode == 'delta'
    local id = newId('c')

    -- Players: qbx_core players table inventories
    local pWhere = delta and 'last_updated >= FROM_UNIXTIME(?) AND ' or ''
    local pParams = delta and { since } or {}
    local complete = censusPages(id, mode, since, 'player',
        'SELECT COUNT(*) FROM players' .. (delta and ' WHERE last_updated >= FROM_UNIXTIME(?)' or ''), pParams,
        function(cursor, per)
            local q = { table.unpack(pParams) }
            q[#q + 1] = cursor or ''
            local rows = db.query(
                ('SELECT citizenid, inventory FROM players WHERE %s citizenid > ? ORDER BY citizenid LIMIT %d'):format(pWhere, per), q)
            if type(rows) ~= 'table' then return nil end
            local out = {}
            for i = 1, #rows do out[i] = { rows[i].citizenid, rows[i].inventory or '[]' } end
            return out, rows[#rows] and rows[#rows].citizenid, #rows
        end)

    -- Stashes: ox_inventory stashes; owner is NULL or '' for shared stashes
    local sWhere = delta and 'lastupdated >= FROM_UNIXTIME(?) AND ' or ''
    complete = complete and censusPages(id, mode, since, 'stash',
        'SELECT COUNT(*) FROM ox_inventory' .. (delta and ' WHERE lastupdated >= FROM_UNIXTIME(?)' or ''), pParams,
        function(cursor, per)
            local q = { table.unpack(pParams) }
            q[#q + 1] = cursor and cursor[1] or ''
            q[#q + 1] = cursor and cursor[2] or ''
            local rows = db.query(([[SELECT COALESCE(owner, '') AS o, name, data FROM ox_inventory
                WHERE %s (COALESCE(owner, ''), name) > (?, ?) ORDER BY COALESCE(owner, ''), name LIMIT %d]]):format(sWhere, per), q)
            if type(rows) ~= 'table' then return nil end
            local out = {}
            for i = 1, #rows do
                local r = rows[i]
                out[i] = { r.o == '' and r.name or (r.name .. ':' .. r.o), r.data or '[]' }
            end
            local l = rows[#rows]
            return out, l and { l.o, l.name }, #rows
        end)

    -- Trunks and gloveboxes: player_vehicles has no change timestamp for them, so they are always sent in full
    for _, col in ipairs({ 'trunk', 'glovebox' }) do
        complete = complete and censusPages(id, 'full', nil, col,
            ('SELECT COUNT(*) FROM player_vehicles WHERE %s IS NOT NULL'):format(col), {},
            function(cursor, per)
                local rows = db.query(
                    ('SELECT id, %s AS d FROM player_vehicles WHERE %s IS NOT NULL AND id > ? ORDER BY id LIMIT %d'):format(col, col, per),
                    { cursor or 0 })
                if type(rows) ~= 'table' then return nil end
                local out = {}
                for i = 1, #rows do out[i] = { tostring(rows[i].id), rows[i].d } end
                return out, rows[#rows] and rows[#rows].id, #rows
            end)
    end

    -- Watermark: moves only after every kind finished, so a failed page makes the next run cover the same rows
    if not complete then return end
    kvpSet('atlas:census_since', watermark(dbNow))
    if mode == 'full' then kvpSet('atlas:census_full_at', os.time()) end
end

local function vehiclesCensus()
    local rows = db.query('SELECT vehicle, COUNT(*) AS n FROM player_vehicles GROUP BY vehicle')
    if type(rows) ~= 'table' then return end
    local out = {}
    for i = 1, #rows do out[i] = { tostring(rows[i].vehicle), tonumber(rows[i].n) or 0 } end
    Atlas.emit('vehicles.census', { census_id = newId('v'), rows = out })
end

-- Vehicles owned: hooks only see vehicles bought or handed over while Atlas runs, so this full list fills the gaps.
-- Privacy: sends model hash and plate hash per owner, never the plate; paged by id, one page per slice.
local function vehiclesOwned()
    local per = cfg.censusPageRows
    local pages = pagesFor(db.scalar('SELECT COUNT(*) FROM player_vehicles WHERE citizenid IS NOT NULL'), 0, per)
    local id, page, cursor = newId('o'), 0, 0
    while true do
        local rows = db.query((
            'SELECT id, citizenid, hash, vehicle, plate FROM player_vehicles ' ..
            'WHERE citizenid IS NOT NULL AND id > ? ORDER BY id LIMIT %d'
        ):format(per), { cursor })
        if type(rows) ~= 'table' then Atlas.warn('vehicles.owned page failed') return end
        local out = {}
        for i = 1, #rows do
            local r = rows[i]
            local model = tonumber(r.hash)
            if not model and type(r.vehicle) == 'string' then model = GetHashKey(r.vehicle) end
            local plate = type(r.plate) == 'string' and r.plate:upper():gsub('^%s+', ''):gsub('%s+$', '') or nil
            out[i] = { r.citizenid, model and common.u32(model) or 0, plate and common.u32(GetHashKey(plate)) or 0 }
            cursor = r.id
        end
        page = page + 1
        if page > pages then pages = page end
        local done = #rows < per
        Atlas.emit('vehicles.owned', { snapshot_id = id, rows = out, page = page, pages = pages, final = done or nil })
        if done then return end
        Wait(200)
    end
end

-- Prices catalog: vehicle, item and property prices.
local function emitChunks(kind, entries)
    for i = 1, #entries, 500 do
        Atlas.emit('prices.catalog', { kind = kind, entries = { table.unpack(entries, i, math.min(i + 499, #entries)) } })
    end
end

function Atlas.pricesCatalog()
    if GetResourceState('qbx_core') == 'started' then
        local ok, vehicles = pcall(function() return exports.qbx_core:GetVehiclesByName() end)
        if ok and type(vehicles) == 'table' then
            local entries = {}
            for model, v in pairs(vehicles) do
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
            emitChunks('vehicle', entries)
        end
    end
    -- Properties: qbx_properties houses and apartments for sale only; rentals and free apartments (price 0) are skipped
    if GetResourceState('qbx_properties') == 'started' and db.available() then
        local rows = db.query(
            'SELECT id, property_name, price FROM properties WHERE price > 0 AND rent_interval IS NULL ORDER BY id LIMIT 5000')
        if type(rows) == 'table' and #rows > 0 then
            local entries = {}
            for i = 1, #rows do
                entries[i] = { tostring(rows[i].id), tostring(rows[i].property_name or ''), tonumber(rows[i].price) or 0, '', 'property' }
            end
            emitChunks('property', entries)
        end
    end
    local shops = Atlas.loadOxShops and Atlas.loadOxShops()
    if shops then
        local entries, seen = {}, {}
        for shopType, shop in pairs(shops) do
            if type(shop) == 'table' and type(shop.inventory) == 'table' then
                for _, it in sandbox.items(shop.inventory) do
                    if type(it) == 'table' and type(it.name) == 'string' and tonumber(it.price) then
                        local key = it.name .. '@' .. shopType
                        if not seen[key] then
                            seen[key] = true
                            entries[#entries + 1] = { it.name, '', tonumber(it.price), tostring(shopType) }
                        end
                    end
                end
            end
        end
        emitChunks('item', entries)
    end
end

-- Scheduler: runs each snapshot on its interval while the agent is enabled and oxmysql is up.
local function run(name, fn, ...)
    if busy then return false end
    busy = true
    local t0 = GetGameTimer()
    local ok, err = pcall(fn, ...)
    busy = false
    if not ok then Atlas.warn('%s failed: %s', name, tostring(err)) end
    Atlas.debug('%s took %d ms', name, GetGameTimer() - t0)
    return true
end

--- Run queued: waits for the snapshot in progress to finish, up to 5 minutes, then runs.
local function runQueued(name, fn, ...)
    for _ = 1, 60 do
        if not busy then return run(name, fn, ...) end
        Wait(5000)
    end
    return false
end

local function censusDue()
    local today = os.date('%Y-%m-%d')
    if GetResourceKvpString('atlas:census_day') == today then return nil end
    local firstEver = kvpNum('atlas:census_full_at') == nil
    if not firstEver and tonumber(os.date('%H')) ~= cfg.censusHour then return nil end
    local lastFull = kvpNum('atlas:census_full_at') or 0
    if firstEver or tonumber(os.date('%w')) == cfg.censusFullWeekday or os.time() - lastFull > 8 * 86400 then
        return 'full', today
    end
    return 'delta', today
end

AddEventHandler('onResourceStart', function(res)
    if (res == 'qbx_core' or res == 'ox_inventory' or res == 'qbx_properties') and cfg.snapshots then
        CreateThread(function()
            Wait(15000)
            if Atlas.enabled then runQueued('prices.catalog', Atlas.pricesCatalog) end
        end)
    end
end)

CreateThread(function()
    if not cfg.snapshots then return end
    -- Startup delay: lets adapters attach and oxmysql connect
    Wait(20000)
    while true do
        if Atlas.enabled and db.available() then
            local now = GetGameTimer()
            if not catalogDone then
                catalogDone = run('prices.catalog', Atlas.pricesCatalog)
            end
            if moneySince == nil then
                -- Retry: the full run repeats every 30 s until the database answers
                run('money.snapshot full', moneySnapshot, 'full')
                lastMoneyAt = now
            elseif now - lastMoneyAt >= cfg.moneyEveryMin * 60000 then
                local lastFull = kvpNum('atlas:money_full_at') or 0
                local mode = (os.time() - lastFull > 7 * 86400) and 'full' or 'delta'
                if run('money.snapshot', moneySnapshot, mode) then lastMoneyAt = now end
            end
            if now - lastAccountsAt >= cfg.accountsEveryMin * 60000 then
                if run('accounts.snapshot', accountsSnapshot) then lastAccountsAt = now end
            end
            local mode, today = censusDue()
            if mode and not busy then
                SetResourceKvp('atlas:census_day', today)
                run('items.census ' .. mode, itemsCensus, mode)
                run('vehicles.census', vehiclesCensus)
                run('vehicles.owned', vehiclesOwned)
            end
        end
        Wait(30000)
    end
end)

Atlas.snapshots = {
    money = function(mode) return run('money.snapshot', moneySnapshot, mode or 'delta') end,
    accounts = function() return run('accounts.snapshot', accountsSnapshot) end,
    census = function(mode) return run('items.census', itemsCensus, mode or 'delta') end,
    vehicles = function() return run('vehicles.owned', vehiclesOwned) end,
    busy = function() return busy end,
}
