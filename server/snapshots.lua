-- Snapshots: reads game data through oxmysql and sends it as events, so Atlas never needs database access.
-- Paging: rows are read in pages with a pause between them; changes-only runs use the database clock.
-- Readers: the framework adapter supplies the queries (Atlas.reader); this file pages, adds live data and sends.

local cfg = AtlasConfig
local floor, ceil = math.floor, math.ceil
local db = Atlas.db

local busy = false
local runCounter = 0
local moneySince      -- moneySince: database clock (s) at the start of the previous money run
local lastMoneyAt, lastAccountsAt = 0, 0
local catalogDone = false

-- Watermark: the second before a run started, so rows saved in that second are read again, never missed
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
-- Reader: { delta, count(since), page(since, cursor, limit), init? }; a reader without delta sends online players only in delta mode.
-- Init: runs before each snapshot and may query, for readers that learn from the database whether they can find changed rows.
local function moneySnapshot(mode)
    local reader = Atlas.reader('money')
    if not reader then return end
    if reader.init then reader.init() end
    local dbNow, err = db.now()
    if not dbNow then return Atlas.warn('money snapshot skipped: %s', tostring(err)) end
    local since = (mode == 'delta') and moneySince or nil
    if mode == 'delta' and not since then mode = 'full' end
    local fromDb = mode == 'full' or reader.delta

    local count = fromDb and reader.count(since) or 0

    -- Online players: always sent with live balances, since the database lags until the framework saves
    local online, onlineN = {}, 0
    for char, m in pairs(Atlas.onlineBalances and Atlas.onlineBalances() or {}) do
        online[char] = { m.cash or 0, m.bank or 0, m.crypto or 0 }
        onlineN = onlineN + 1
    end

    local per = cfg.moneyPageRows
    local pages = pagesFor(count, onlineN, per)
    local id = newId('m')
    local page, cursor, emitted = 0, nil, {}

    while true do
        local rows, nextCursor, got = {}, nil, 0
        if fromDb then
            rows, nextCursor, got = reader.page(since, cursor, per)
            if not rows then return Atlas.warn('money snapshot page failed') end -- watermark stays, so the next run is full
        end
        local out = {}
        for i = 1, #rows do
            local r = rows[i]
            local live = online[r[1]]
            if live then
                out[i] = { r[1], live[1], live[2], live[3] }
                emitted[r[1]] = true
            else
                out[i] = r
            end
        end
        cursor = nextCursor
        local done = got < per
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

-- Accounts snapshot: society and business balances from the active account sources.
local function accountsSnapshot()
    local rows, err = Atlas.accountsRows()
    if not rows then return Atlas.debug('accounts snapshot skipped: %s', tostring(err)) end
    Atlas.emit('accounts.snapshot', { snapshot_id = newId('a'), rows = rows })
end

-- Census: items and vehicles.
-- Kinds: { kind, order, delta, count(since), page(since, cursor, limit) }; the framework supplies player and vehicle kinds,
-- and sources of kind 'census' add the rest (stashes). A kind without delta is always sent in full.
local function censusKinds()
    local get = Atlas.reader('census')
    local kinds = get and get() or {}
    for _, def in ipairs(Atlas.sources('census')) do kinds[#kinds + 1] = def end
    table.sort(kinds, function(a, b) return (a.order or 50) < (b.order or 50) end)
    return #kinds > 0 and kinds or nil
end

local function censusPages(id, mode, since, kind, accounts)
    local per = cfg.censusPageRows
    local pages = pagesFor(kind.count(since), 0, per)
    local page, cursor = 0, nil
    while true do
        local rows, nextCursor, got = kind.page(since, cursor, per)
        if not rows then Atlas.warn('census %s page failed', kind.kind) return false end
        page = page + 1
        if page > pages then pages = page end
        local done = got < per
        Atlas.emit('items.census', {
            census_id = id, mode = mode, since_ts = toMs(since), holder_kind = kind.kind,
            rows = rows, page = page, pages = pages, final = done or nil, accounts = accounts,
        })
        if done then return true end
        cursor = nextCursor
        Wait(200)
    end
end

local function itemsCensus(mode)
    local kinds = censusKinds()
    if not kinds then return end
    local dbNow = db.now()
    if not dbNow then return end
    local since = (mode == 'delta') and kvpNum('atlas:census_since') or nil
    if mode == 'delta' and not since then mode = 'full' end
    local id = newId('c')
    local accounts = Atlas.framework and Atlas.framework.inventoryAccounts

    local complete = true
    for _, kind in ipairs(kinds) do
        if kind.delta then
            complete = complete and censusPages(id, mode, since, kind, accounts)
        else
            complete = complete and censusPages(id, 'full', nil, kind, accounts)
        end
    end

    -- Watermark: moves only after every kind finished, so a failed page makes the next run cover the same rows
    if not complete then return end
    kvpSet('atlas:census_since', watermark(dbNow))
    if mode == 'full' then kvpSet('atlas:census_full_at', os.time()) end
end

local function vehiclesCensus()
    local reader = Atlas.reader('vehicles')
    local rows = reader and reader.census and reader.census()
    if type(rows) ~= 'table' then return end
    Atlas.emit('vehicles.census', { census_id = newId('v'), rows = rows })
end

-- Vehicles owned: hooks only see vehicles bought or handed over while Atlas runs; this list fills the gaps.
-- Privacy: sends a hash of the model and plate for each owner, never the plate itself.
-- Reader: { count(), page(cursor, limit) } with rows of [owner char, model hash, plate hash].
local function vehiclesOwned()
    local reader = Atlas.reader('vehicles')
    local owned = reader and reader.owned
    if not owned then return end
    local per = cfg.censusPageRows
    local pages = pagesFor(owned.count(), 0, per)
    local id, page, cursor = newId('o'), 0, nil
    while true do
        local rows, nextCursor, got = owned.page(cursor, per)
        if not rows then Atlas.warn('vehicles.owned page failed') return end
        cursor = nextCursor
        page = page + 1
        if page > pages then pages = page end
        local done = got < per
        Atlas.emit('vehicles.owned', { snapshot_id = id, rows = rows, page = page, pages = pages, final = done or nil })
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

--- Prices catalog: each active prices source reads its own data and hands it over as entries of one kind.
function Atlas.pricesCatalog()
    for _, def in ipairs(Atlas.sources('prices')) do
        local ok, err = pcall(def.read, emitChunks)
        if not ok then Atlas.warn('prices from %s failed: %s', def.name, tostring(err)) end
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
    if firstEver or tonumber(os.date('%w')) == cfg.censusFullWeekday or os.time() - lastFull > cfg.censusFullMaxDays * 86400 then
        return 'full', today
    end
    return 'delta', today
end

AddEventHandler('onResourceStart', function(res)
    if cfg.snapshots and Atlas.sourceResources('prices')[res] then
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
            local money = Atlas.reader('money')
            if money and moneySince == nil then
                -- Retry: the full run repeats every 30 s until the database answers
                run('money.snapshot full', moneySnapshot, 'full')
                lastMoneyAt = now
            elseif money and now - lastMoneyAt >= cfg.moneyEveryMin * 60000 then
                -- Full: readers that cannot find changed rows run full on a short cycle, the others once a week
                local lastFull = kvpNum('atlas:money_full_at') or 0
                local fullAfter = money.delta and cfg.moneyFullEveryDays * 86400 or cfg.moneyFullEveryMin * 60
                local mode = (os.time() - lastFull > fullAfter) and 'full' or 'delta'
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
