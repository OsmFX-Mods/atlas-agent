local fx = load_module('tests/fivem.lua')

local DB_NOW = 1790000100.5

local function boot(convars)
    convars = convars or { ['atlas:snapshots'] = 0 }
    convars['atlas:token'] = 'atl_live_x'
    fx.boot({ convars = convars, load = {
        'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua',
        'server/adapters/qbox_data.lua', 'server/adapters/ox_inventory_data.lua', 'server/snapshots.lua',
    } })
    Atlas.framework = { name = 'qbox', data = Atlas.frameworkData.qbox }
    AtlasConfig.moneyPageRows = 2
    AtlasConfig.censusPageRows = 2
end

--- Fake database: serves pages of `rows`, sorted by `key`, and records every query.
local function fakeDb(rows, key, opts)
    opts = opts or {}
    local db = Atlas.db
    local log = {}
    table.sort(rows, function(a, b) return a[key] < b[key] end)
    db.available = function() return true end
    db.now = function() return DB_NOW end
    db.scalar = function() return #rows end
    db.query = function(sql, params)
        params = params or {}
        log[#log + 1] = { sql = sql, params = params }
        if opts.failAfter and #log > opts.failAfter then return nil end
        local last = params[#params]
        if last == nil then return {} end
        local limit = tonumber(sql:match('LIMIT (%d+)'))
        local out = {}
        for _, r in ipairs(rows) do
            if r[key] > last then
                out[#out + 1] = r
                if #out == limit then break end
            end
        end
        return out
    end
    return log
end

--- Run: executes `fn` inside a thread, since snapshots wait between pages, and returns once it finished.
local function run(fn)
    local done = false
    CreateThread(function() fn(); done = true end)
    fx.advance(60000, 100)
    return done
end

local function snapshots(etype)
    Atlas.jsReady = true
    Atlas.flush()
    local out = {}
    for _, call in ipairs(fx.triggered('atlas:internal:batch')) do
        for _, ev in ipairs(call[1]) do
            if ev.type == etype then out[#out + 1] = ev end
        end
    end
    return out
end

local function character(id, cash, bank)
    return { citizenid = id, cash = cash, bank = bank, crypto = 0 }
end

local function fiveCharacters()
    return {
        character('AAA', 1, 10), character('BBB', 2, 20), character('CCC', 3, 30),
        character('DDD', 4, 40), character('EEE', 5, 50),
    }
end

describe('money snapshot', function()
    it('pages through every character with a final flag only on the last page', function()
        boot()
        fakeDb(fiveCharacters(), 'citizenid')
        expect(run(function() Atlas.snapshots.money('full') end)).toBe(true)
        local pages = snapshots('money.snapshot')
        expect(#pages).toBe(3)
        local seen = {}
        for i, ev in ipairs(pages) do
            expect(ev.data.mode).toBe('full')
            expect(ev.data.page).toBe(i)
            expect(ev.data.pages).toBe(3)
            expect(ev.data.final).toBe(i == 3 or nil)
            for _, row in ipairs(ev.data.rows) do seen[#seen + 1] = row[1] end
        end
        expect(seen).toEqual({ 'AAA', 'BBB', 'CCC', 'DDD', 'EEE' })
        expect(pages[1].data.rows[1]).toEqual({ 'AAA', 1, 10, 0 })
        expect(pages[1].data.snapshot_id == pages[3].data.snapshot_id).toBe(true)
        fx.teardown()
    end)

    it('ends with an empty final page when the row count is an exact multiple of the page size', function()
        boot()
        local rows = { character('AAA', 1, 1), character('BBB', 2, 2), character('CCC', 3, 3), character('DDD', 4, 4) }
        fakeDb(rows, 'citizenid')
        run(function() Atlas.snapshots.money('full') end)
        local pages = snapshots('money.snapshot')
        expect(#pages).toBe(3)
        expect(#pages[3].data.rows).toBe(0)
        expect(pages[3].data.final).toBe(true)
        fx.teardown()
    end)

    it('uses live balances for online characters and appends those the query missed', function()
        boot()
        fakeDb(fiveCharacters(), 'citizenid')
        Atlas.onlineBalances = function()
            return { BBB = { cash = 999, bank = 888 }, ZZZ = { cash = 7, bank = 8, crypto = 9 } }
        end
        run(function() Atlas.snapshots.money('full') end)
        local pages = snapshots('money.snapshot')
        expect(pages[1].data.rows[2]).toEqual({ 'BBB', 999, 888, 0 })
        local lastRows = pages[#pages].data.rows
        expect(lastRows[#lastRows]).toEqual({ 'ZZZ', 7, 8, 9 })
        fx.teardown()
    end)

    it('turns a delta request into a full run when no full run came first', function()
        boot()
        fakeDb(fiveCharacters(), 'citizenid')
        run(function() Atlas.snapshots.money('delta') end)
        expect(snapshots('money.snapshot')[1].data.mode).toBe('full')
        fx.teardown()
    end)

    it('asks for rows changed since the previous run using the database clock', function()
        boot()
        local log = fakeDb(fiveCharacters(), 'citizenid')
        run(function() Atlas.snapshots.money('full') end)
        local before = #log
        run(function() Atlas.snapshots.money('delta') end)
        local delta = snapshots('money.snapshot')
        local last = delta[#delta]
        expect(last.data.mode).toBe('delta')
        expect(last.data.since_ts).toBe((math.floor(DB_NOW) - 1) * 1000)
        expect(log[before + 1].params[1]).toBe(math.floor(DB_NOW) - 1)
        expect(log[before + 1].sql:find('last_updated >= FROM_UNIXTIME', 1, true) ~= nil).toBe(true)
        fx.teardown()
    end)

    it('stops on a failed page and does not advance the delta watermark', function()
        boot()
        fakeDb(fiveCharacters(), 'citizenid', { failAfter = 1 })
        run(function() Atlas.snapshots.money('full') end)
        expect(#snapshots('money.snapshot')).toBe(1)
        expect(#fx.printed('page failed')).toBe(1)
        fx.state.triggered = {}
        fakeDb(fiveCharacters(), 'citizenid')
        run(function() Atlas.snapshots.money('delta') end)
        expect(snapshots('money.snapshot')[1].data.mode).toBe('full')
        fx.teardown()
    end)

    it('skips the run when the database clock is unavailable', function()
        boot()
        fakeDb(fiveCharacters(), 'citizenid')
        Atlas.db.now = function() return nil, 'oxmysql not started' end
        run(function() Atlas.snapshots.money('full') end)
        expect(#snapshots('money.snapshot')).toBe(0)
        expect(#fx.printed('money snapshot skipped')).toBe(1)
        fx.teardown()
    end)

    it('refuses a second run while one is in progress', function()
        boot()
        fakeDb(fiveCharacters(), 'citizenid')
        local results = {}
        CreateThread(function() results.first = Atlas.snapshots.money('full') end)
        CreateThread(function() results.second = Atlas.snapshots.money('full') end)
        fx.advance(60000, 100)
        expect(results.first).toBe(true)
        expect(results.second).toBe(false)
        fx.teardown()
    end)
end)

describe('vehicles owned snapshot', function()
    local function vehicles()
        return {
            { id = 1, citizenid = 'AAA', hash = 1234, vehicle = 'adder', plate = '  ab 123 ' },
            { id = 2, citizenid = 'BBB', hash = nil, vehicle = 'zentorno', plate = 'XYZ789' },
            { id = 3, citizenid = 'CCC', hash = '0', vehicle = nil, plate = nil },
        }
    end

    it('sends owner, model hash and a plate hash, never the plate itself', function()
        boot()
        fakeDb(vehicles(), 'id')
        run(function() Atlas.snapshots.vehicles() end)
        local pages = snapshots('vehicles.owned')
        expect(#pages).toBe(2)
        local rows = {}
        for _, ev in ipairs(pages) do for _, r in ipairs(ev.data.rows) do rows[#rows + 1] = r end end
        expect(#rows).toBe(3)
        local common = AtlasLib.common
        expect(rows[1]).toEqual({ 'AAA', 1234, common.u32(fx.joaat('AB 123')) })
        expect(rows[2]).toEqual({ 'BBB', common.u32(fx.joaat('zentorno')), common.u32(fx.joaat('XYZ789')) })
        for _, r in ipairs(rows) do
            for _, v in ipairs(r) do expect(v == 'AB 123' or v == 'XYZ789').toBe(false) end
        end
        expect(pages[2].data.final).toBe(true)
        expect(pages[1].data.final).toBeNil()
        fx.teardown()
    end)

    it('uses 0 when a model or plate is unknown', function()
        boot()
        fakeDb(vehicles(), 'id')
        run(function() Atlas.snapshots.vehicles() end)
        local pages = snapshots('vehicles.owned')
        local third = pages[2].data.rows[1]
        expect(third).toEqual({ 'CCC', 0, 0 })
        fx.teardown()
    end)
end)

describe('snapshot scheduler', function()
    it('waits for startup, sends a full money snapshot, then deltas every 15 minutes', function()
        boot({ ['atlas:snapshots'] = 1 })
        fakeDb(fiveCharacters(), 'citizenid')
        fx.advance(15000, 1000)
        expect(#snapshots('money.snapshot')).toBe(0)
        fx.advance(15000, 1000)
        local first = snapshots('money.snapshot')
        expect(first[1].data.mode).toBe('full')
        fx.state.triggered = {}
        fx.advance(14 * 60000, 5000)
        expect(#snapshots('money.snapshot')).toBe(0)
        fx.state.triggered = {}
        fx.advance(2 * 60000, 5000)
        local later = snapshots('money.snapshot')
        expect(#later > 0).toBe(true)
        expect(later[1].data.mode).toBe('delta')
        fx.teardown()
    end)

    it('does nothing when snapshots are switched off', function()
        boot()
        fakeDb(fiveCharacters(), 'citizenid')
        fx.advance(120000, 5000)
        expect(#snapshots('money.snapshot')).toBe(0)
        fx.teardown()
    end)

    it('does nothing while oxmysql is down', function()
        boot({ ['atlas:snapshots'] = 1 })
        fakeDb(fiveCharacters(), 'citizenid')
        Atlas.db.available = function() return false end
        fx.advance(120000, 5000)
        expect(#snapshots('money.snapshot')).toBe(0)
        fx.teardown()
    end)
end)

describe('items census', function()
    local function bootCensus(query)
        boot()
        fx.state.resources.ox_inventory = 'started'
        local db = Atlas.db
        db.available = function() return true end
        db.now = function() return DB_NOW end
        db.scalar = function() return 0 end
        db.query = query
    end

    it('covers players, stashes, trunks and gloveboxes and then moves the watermark', function()
        bootCensus(function() return {} end)
        run(function() Atlas.snapshots.census('full') end)
        local kinds = {}
        for _, ev in ipairs(snapshots('items.census')) do kinds[#kinds + 1] = ev.data.holder_kind end
        expect(kinds).toEqual({ 'player', 'stash', 'trunk', 'glovebox' })
        expect(fx.state.kvp['atlas:census_since']).toBe(tostring(math.floor(DB_NOW) - 1))
        expect(fx.state.kvp['atlas:census_full_at'] ~= nil).toBe(true)
        fx.teardown()
    end)

    it('keeps the watermark when a page fails so the next run covers the same rows', function()
        bootCensus(function() return nil end)
        run(function() Atlas.snapshots.census('full') end)
        expect(fx.state.kvp['atlas:census_since']).toBeNil()
        expect(fx.state.kvp['atlas:census_full_at']).toBeNil()
        expect(#fx.printed('census player page failed')).toBe(1)
        fx.teardown()
    end)

    it('does nothing when ox_inventory is not started', function()
        bootCensus(function() return {} end)
        fx.state.resources.ox_inventory = nil
        run(function() Atlas.snapshots.census('full') end)
        expect(#snapshots('items.census')).toBe(0)
        fx.teardown()
    end)
end)

describe('catalog on resource start', function()
    it('waits for a running snapshot instead of dropping the refresh', function()
        boot({ ['atlas:snapshots'] = 1 })
        fakeDb(fiveCharacters(), 'citizenid')
        local calls = 0
        Atlas.pricesCatalog = function() calls = calls + 1 end
        Atlas.db.now = function() Wait(30000) return DB_NOW end
        fx.advance(100)
        CreateThread(function() Atlas.snapshots.money('full') end)
        fx.advance(100)
        expect(Atlas.snapshots.busy()).toBe(true)
        for _, fn in ipairs(fx.state.handlers.onResourceStart) do fn('ox_inventory') end
        fx.advance(40000, 500)
        expect(calls).toBe(1)
        fx.teardown()
    end)
end)

describe('snapshot readers', function()
    it('skips money and vehicles when no framework is attached', function()
        boot()
        Atlas.framework = nil
        fakeDb(fiveCharacters(), 'citizenid')
        run(function() Atlas.snapshots.money('full') end)
        run(function() Atlas.snapshots.vehicles() end)
        expect(#snapshots('money.snapshot')).toBe(0)
        expect(#snapshots('vehicles.owned')).toBe(0)
        fx.teardown()
    end)

    it('still sends stash census without a framework when ox_inventory is started', function()
        boot()
        Atlas.framework = nil
        fx.state.resources.ox_inventory = 'started'
        Atlas.db.available = function() return true end
        Atlas.db.now = function() return DB_NOW end
        Atlas.db.query = function() return {} end
        Atlas.db.scalar = function() return 0 end
        run(function() Atlas.snapshots.census('full') end)
        local kinds = {}
        for _, ev in ipairs(snapshots('items.census')) do kinds[#kinds + 1] = ev.data.holder_kind end
        expect(kinds).toEqual({ 'stash' })
        fx.teardown()
    end)

    it('leaves the accounts list out of the census for Qbox, where money is the default item', function()
        boot()
        fx.state.resources.ox_inventory = 'started'
        Atlas.db.available = function() return true end
        Atlas.db.now = function() return DB_NOW end
        Atlas.db.query = function() return {} end
        Atlas.db.scalar = function() return 0 end
        run(function() Atlas.snapshots.census('full') end)
        for _, ev in ipairs(snapshots('items.census')) do expect(ev.data.accounts).toBeNil() end
        fx.teardown()
    end)

    it('orders census kinds by their order value and always sends kinds without delta in full', function()
        boot()
        fx.state.resources.ox_inventory = 'started'
        Atlas.db.available = function() return true end
        Atlas.db.now = function() return DB_NOW end
        Atlas.db.query = function() return {} end
        Atlas.db.scalar = function() return 0 end
        run(function() Atlas.snapshots.census('delta') end)
        local seen = {}
        for _, ev in ipairs(snapshots('items.census')) do seen[ev.data.holder_kind] = ev.data.mode end
        expect(seen.player).toBe('full') -- no watermark yet, so the first run is full
        expect(seen.trunk).toBe('full')
        fx.state.kvp['atlas:census_since'] = '1790000000'
        fx.state.triggered = {}
        run(function() Atlas.snapshots.census('delta') end)
        seen = {}
        for _, ev in ipairs(snapshots('items.census')) do seen[ev.data.holder_kind] = ev.data.mode end
        expect(seen.player).toBe('delta')
        expect(seen.stash).toBe('delta')
        expect(seen.trunk).toBe('full')
        expect(seen.glovebox).toBe('full')
        fx.teardown()
    end)

    it('reads from the configured table names', function()
        boot()
        local log = fakeDb(fiveCharacters(), 'citizenid')
        AtlasConfig.qbox.tables.characters = 'my_players'
        run(function() Atlas.snapshots.money('full') end)
        expect(log[1].sql:find('FROM `my_players`', 1, true) ~= nil).toBe(true)
        fx.teardown()
    end)

    it('warns and sends nothing for an invalid table name', function()
        boot()
        fakeDb(fiveCharacters(), 'citizenid')
        AtlasConfig.qbox.tables.characters = 'players; DROP'
        run(function() Atlas.snapshots.money('full') end)
        expect(#snapshots('money.snapshot')).toBe(0)
        expect(#fx.printed('qbox.tables.characters is not a valid table name') > 0).toBe(true)
        fx.teardown()
    end)

    it('calls a reader init before each money snapshot', function()
        boot()
        fakeDb(fiveCharacters(), 'citizenid')
        local inits = 0
        Atlas.framework.data.money.init = function() inits = inits + 1 end
        run(function() Atlas.snapshots.money('full') end)
        expect(inits).toBe(1)
        fx.teardown()
    end)
end)
