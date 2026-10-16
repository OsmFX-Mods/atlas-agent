local fx = load_module('tests/fivem.lua')

local DB_NOW = 1790000100.5

local state

local function boot(resources, files, convars)
    state = { jobs = { police = {} }, rows = {}, scalars = {}, queries = {} }
    local ESX = { GetPlayerFromId = function() return nil end, GetJobs = function() return state.jobs end }
    local res = { es_extended = 'started' }
    for k, v in pairs(resources or {}) do res[k] = v end
    fx.boot({
        convars = convars or { ['atlas:token'] = 'atl_live_x', ['atlas:snapshots'] = 0 }, resources = res, files = files or {},
        provided = { es_extended = { getSharedObject = function() return ESX end } },
        load = {
            'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua',
            'server/characters.lua', 'server/money.lua', 'server/adapters/esx_data.lua', 'server/adapters/esx.lua',
            'server/adapters/ox_inventory_data.lua', 'server/adapters/renewed_banking.lua', 'server/snapshots.lua', 'server/places.lua',
        },
    })
    AtlasConfig.moneyPageRows = 2
    AtlasConfig.censusPageRows = 2
    local db = Atlas.db
    db.available = function() return true end
    db.now = function() return DB_NOW end
    db.scalar = function(sql)
        state.queries[#state.queries + 1] = sql
        if sql:find('information_schema', 1, true) then return state.extra, state.extraErr end
        return state.count or #state.rows
    end
    db.query = function(sql, params)
        state.queries[#state.queries + 1] = sql
        state.lastParams = params
        if state.queryFn then return state.queryFn(sql, params) end
        return state.rows
    end
    fx.advance(200)
end

local function events(etype)
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

--- Run: executes `fn` in a thread, since snapshots wait between pages.
local function run(fn)
    local done = false
    CreateThread(function() fn(); done = true end)
    fx.advance(60000, 100)
    return done
end

local function data() return Atlas.frameworkData.esx end

describe('esx money reader', function()
    it('decodes the accounts column into cash, bank and crypto', function()
        boot()
        state.rows = {
            { identifier = 'char1:a', accounts = '{"money":10,"bank":200,"black_money":5}' },
            { identifier = 'char1:b', accounts = '' },
            { identifier = 'char1:c', accounts = '{"bank":"7"}' },
        }
        local rows, cursor, got = data().money.page(nil, nil, 2)
        expect(rows).toEqual({ { 'char1:a', 15, 200, 0 }, { 'char1:b', 0, 0, 0 }, { 'char1:c', 0, 7, 0 } })
        expect(cursor).toBe('char1:c')
        expect(got).toBe(3)
        fx.teardown()
    end)

    it('tolerates broken or empty account data', function()
        boot()
        state.rows = { { identifier = 'a', accounts = 'not json' }, { identifier = 'b', accounts = nil }, { identifier = 'c', accounts = '[1]' } }
        local rows = data().money.page(nil, nil, 5)
        expect(rows).toEqual({ { 'a', 0, 0, 0 }, { 'b', 0, 0, 0 }, { 'c', 0, 0, 0 } })
        fx.teardown()
    end)

    it('uses only the accounts named in the config', function()
        boot()
        AtlasConfig.esx.accounts = { bank = 'bank', tokens = 'crypto' }
        state.rows = { { identifier = 'a', accounts = '{"money":10,"bank":20,"tokens":3}' } }
        expect(data().money.page(nil, nil, 5)).toEqual({ { 'a', 0, 20, 3 } })
        fx.teardown()
    end)

    it('uses the configured table name and rejects an invalid one', function()
        boot()
        AtlasConfig.esx.tables.characters = 'my_users'
        data().money.page(nil, nil, 5)
        expect(state.queries[#state.queries]:find('FROM `my_users`', 1, true) ~= nil).toBe(true)
        AtlasConfig.esx.tables.characters = 'users; DROP TABLE x'
        expect(data().money.page(nil, nil, 5)).toBeNil()
        expect(#fx.printed('esx.tables.characters is not a valid table name')).toBe(1)
        fx.teardown()
    end)

    it('pages by identifier and filters on the changed column when given a start time', function()
        boot()
        state.extra = 'on update CURRENT_TIMESTAMP'
        data().money.init()
        data().money.page(1790000000, 'char1:a', 5)
        expect(state.queries[#state.queries]:find('`last_seen` >= FROM_UNIXTIME(?) AND identifier > ?', 1, true) ~= nil).toBe(true)
        expect(state.lastParams).toEqual({ 1790000000, 'char1:a' })
        fx.teardown()
    end)
end)

describe('esx changed rows', function()
    it('finds changed rows when the column updates with the row', function()
        boot()
        state.extra = 'on update CURRENT_TIMESTAMP'
        data().money.init()
        expect(data().money.delta).toBe(true)
        fx.teardown()
    end)

    it('does not when the column is plain or missing', function()
        boot()
        state.extra = ''
        data().money.init()
        expect(data().money.delta).toBe(false)
        fx.teardown()
        boot()
        state.extra = nil
        data().money.init()
        expect(data().money.delta).toBe(false)
        fx.teardown()
    end)

    it('does not when the config names no column', function()
        boot()
        AtlasConfig.esx.changedColumn = ''
        data().money.init()
        expect(data().money.delta).toBe(false)
        fx.teardown()
    end)

    it('asks again on the next run after a database error', function()
        boot()
        state.extraErr = 'timeout'
        data().money.init()
        expect(data().money.delta).toBe(false)
        state.extraErr = nil
        state.extra = 'on update CURRENT_TIMESTAMP'
        data().money.init()
        expect(data().money.delta).toBe(true)
        fx.teardown()
    end)
end)

describe('esx census reader', function()
    it('turns the native name to count table into a list and leaves ox inventories as they are', function()
        boot()
        state.rows = {
            { identifier = 'a', inventory = '{"water":2,"bread":1,"empty":0}' },
            { identifier = 'b', inventory = '[{"name":"water","count":1,"slot":1}]' },
            { identifier = 'c', inventory = nil },
            { identifier = 'd', inventory = '{"1":{"name":"water","count":1}}' },
        }
        local kinds = data().census()
        expect(#kinds).toBe(1)
        expect(kinds[1].kind).toBe('player')
        local rows = kinds[1].page(nil, nil, 10)
        expect(rows[1][2]).toBe('[{"count":1,"name":"bread"},{"count":2,"name":"water"}]')
        expect(rows[2][2]).toBe('[{"name":"water","count":1,"slot":1}]')
        expect(rows[3][2]).toBe('[]')
        expect(rows[4][2]).toBe('{"1":{"name":"water","count":1}}')
        fx.teardown()
    end)

    it('reads only changed rows in a delta when the column allows it', function()
        boot()
        state.extra = 'on update CURRENT_TIMESTAMP'
        expect(data().census()[1].delta).toBe(true)
        fx.teardown()
        boot()
        state.extra = ''
        expect(data().census()[1].delta).toBe(false)
        fx.teardown()
    end)
end)

describe('esx vehicles reader', function()
    it('sends owner, model hash and plate hash, never the plate', function()
        boot()
        state.rows = {
            { owner = 'char1:a', plate = 'AB 123  ', vehicle = '{"model":-1234,"plate":"AB 123"}' },
            { owner = 'char1:b', plate = 'XYZ789', vehicle = '{"plate":"XYZ789","model":"zentorno"}' },
            { owner = 'char1:c', plate = '', vehicle = nil },
            { owner = 'char1:d', plate = 'Q', vehicle = '{"model":"98765"}' },
        }
        local rows, cursor = data().vehicles.owned.page(nil, 10)
        local common = AtlasLib.common
        expect(rows[1]).toEqual({ 'char1:a', common.u32(-1234), common.u32(fx.joaat('AB 123')) })
        expect(rows[2]).toEqual({ 'char1:b', common.u32(fx.joaat('zentorno')), common.u32(fx.joaat('XYZ789')) })
        expect(rows[3]).toEqual({ 'char1:c', 0, 0 })
        expect(rows[4][2]).toBe(98765)
        expect(cursor).toBe('Q')
        for _, r in ipairs(rows) do
            for _, v in ipairs(r) do expect(v == 'AB 123' or v == 'XYZ789').toBe(false) end
        end
        fx.teardown()
    end)

    it('has no per-model census', function()
        boot()
        expect(data().vehicles.census).toBeNil()
        fx.teardown()
    end)
end)

describe('esx groups', function()
    it('lists job names and no gangs', function()
        boot()
        local jobs, gangs = data().groups()
        expect(jobs.police).toBe(true)
        expect(gangs).toEqual({})
        fx.teardown()
    end)
end)

describe('esx accounts source', function()
    it('sends society accounts and classifies the ones named after a job', function()
        boot({ esx_addonaccount = 'started' })
        state.rows = {
            { account_name = 'society_police', money = 1500 }, { account_name = 'society_bar', money = '20' },
            { account_name = 'other', money = 'x' },
        }
        local rows = Atlas.accountsRows()
        expect(rows).toEqual({ { 'society_police', 'job', 1500 }, { 'society_bar', 'business', 20 }, { 'other', 'business', 0 } })
        expect(state.queries[#state.queries]:find('owner IS NULL', 1, true) ~= nil).toBe(true)
        fx.teardown()
    end)

    it('returns the database error', function()
        boot({ esx_addonaccount = 'started' })
        state.queryFn = function() return nil end
        local rows = Atlas.accountsRows()
        expect(rows).toBeNil()
        fx.teardown()
    end)
end)

describe('esx places and prices', function()
    local function placesFor(files, resources)
        boot(resources, files)
        fx.advance(11000)
        return events('places.suggest')
    end

    it('reads garages, hospitals, police stations and shops from their configs', function()
        local chunks = placesFor({
            ['esx_garage/config.lua'] = 'Config = {}\nConfig.Garages = { { label = "Vespucci", entryPoint = vec3(-285.2, -886.5, 31.0) }, { label = "No Point" } }',
            ['esx_ambulancejob/config.lua'] = 'Config = {}\nConfig.Hospitals = { Central = { Blip = { coords = vector3(307.7, -1433.4, 28.9) } }, Broken = {} }',
            ['esx_policejob/config.lua'] = 'Config = {}\nConfig.PoliceStations = { LSPD = { Blip = { Coords = vector3(425.1, -979.5, 30.7) } } }',
            ['esx_shops/shared/config/main.lua'] = 'Config = Config or {}\nConfig.Debug = false',
            ['esx_shops/shared/config/shops.lua'] = 'Config.Zones = Config.Zones or {}\nConfig.Zones.Twenty = { Pos = { vector3(373.8, 325.8, 103.5), vector3(1.0, 2.0, 3.0) } }',
        }, { esx_garage = 'started', esx_ambulancejob = 'started', esx_policejob = 'started', esx_shops = 'started' })
        local byKind = {}
        for _, e in ipairs(chunks[1].data.entries) do byKind[e[2]] = byKind[e[2]] or {}; table.insert(byKind[e[2]], e) end
        expect(#byKind.garage).toBe(1)
        expect(byKind.garage[1][1]).toBe('Vespucci')
        expect(byKind.garage[1][3]).toBe(-285.2)
        expect(byKind.garage[1][5]).toBe(30.0)
        expect(byKind.hospital[1][1]).toBe('Central')
        expect(byKind.hospital[1][5]).toBe(40.0)
        expect(byKind.police[1][1]).toBe('LSPD')
        expect(#byKind.shop).toBe(2)
        expect(byKind.shop[1][1]).toBe('Twenty')
        expect(byKind.shop[1][5]).toBe(15.0)
        fx.teardown()
    end)

    it('reads the garage and shop layouts of ESX versions before 1.16', function()
        local chunks = placesFor({
            ['esx_garage/config.lua'] = 'Config = {}\nConfig.Garages = { VespucciBoulevard = { EntryPoint = { x = -285.2, y = -886.5, z = 31.0 } } }',
            ['esx_shops/config.lua'] = 'Config = {}\nConfig.Zones = { Twenty = { Items = { { name = "bread", label = TranslateCap("bread"), price = 100 } }, Pos = { vector3(373.8, 325.8, 103.5) } } }',
        }, { esx_garage = 'started', esx_shops = 'started' })
        local byKind = {}
        for _, e in ipairs(chunks[1].data.entries) do byKind[e[2]] = byKind[e[2]] or {}; table.insert(byKind[e[2]], e) end
        expect(byKind.garage[1][1]).toBe('VespucciBoulevard')
        expect(byKind.garage[1][3]).toBe(-285.2)
        expect(byKind.shop[1][1]).toBe('Twenty')
        state.rows = {}
        run(function() Atlas.pricesCatalog() end)
        local items
        for _, ev in ipairs(events('prices.catalog')) do if ev.data.kind == 'item' then items = ev.data.entries end end
        expect(items).toEqual({ { 'bread', '', 100, 'Twenty' } })
        fx.teardown()
    end)

    it('skips a resource that is not started', function()
        local chunks = placesFor({ ['esx_garage/config.lua'] = 'Config = {}\nConfig.Garages = { { label = "A", entryPoint = vec3(1.0, 2.0, 3.0) } }' })
        expect(#chunks).toBe(0)
        fx.teardown()
    end)

    it('survives a config that does not load', function()
        local chunks = placesFor({
            ['esx_garage/config.lua'] = 'this is not lua',
            ['esx_policejob/config.lua'] = 'Config = {}\nConfig.PoliceStations = { A = { Blip = { Coords = vec3(1.0, 2.0, 3.0) } } }',
        }, { esx_garage = 'started', esx_policejob = 'started' })
        expect(#chunks[1].data.entries).toBe(1)
        fx.teardown()
    end)

    it('sends vehicle prices from the vehicles table and item prices from the shop zones', function()
        boot({ esx_shops = 'started' }, {
            ['esx_shops/shared/config/main.lua'] = 'Config = Config or {}',
            ['esx_shops/shared/config/shops.lua'] = [[Config.Zones = Config.Zones or {}
                Config.Zones.Twenty = { Items = { { name = "bread", price = 15 }, { name = "bread", price = 99 }, { name = "x" } } }]],
        })
        state.rows = { { model = 'ADDER', name = 'Adder', price = 900000, category = 'super' }, { model = 'x', price = 'no' } }
        run(function() Atlas.pricesCatalog() end)
        local sent = events('prices.catalog')
        local byKind = {}
        for _, ev in ipairs(sent) do byKind[ev.data.kind] = ev.data.entries end
        expect(byKind.vehicle).toEqual({ { 'adder', 'Adder', 900000, '', 'super' } })
        expect(byKind.item).toEqual({ { 'bread', '', 15, 'Twenty' } })
        fx.teardown()
    end)
end)

describe('esx snapshots', function()
    local function snapshots(etype) return events(etype) end

    it('sends a full money snapshot, then online players only, until the full interval passes', function()
        boot(nil, nil)
        state.extra = ''
        state.rows = { { identifier = 'char1:a', accounts = '{"money":10,"bank":20}' } }
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        Atlas.characters.load(4, { char = 'char1:live', money = { cash = 5, bank = 6, crypto = 0 } })
        state.queryFn = function(sql, params)
            if params[#params] ~= '' then return {} end
            return state.rows
        end
        run(function() Atlas.snapshots.money('full') end)
        local first = snapshots('money.snapshot')
        expect(first[1].data.mode).toBe('full')
        local all = {}
        for _, ev in ipairs(first) do for _, r in ipairs(ev.data.rows) do all[r[1]] = r end end
        expect(all['char1:a']).toEqual({ 'char1:a', 10, 20, 0 })
        expect(all['char1:live']).toEqual({ 'char1:live', 5, 6, 0 })

        local before = #state.queries
        fx.state.triggered = {}
        run(function() Atlas.snapshots.money('delta') end)
        local later = snapshots('money.snapshot')
        expect(#later).toBe(1)
        expect(later[1].data.mode).toBe('delta')
        expect(later[1].data.rows).toEqual({ { 'char1:live', 5, 6, 0 } })
        expect(later[1].data.final).toBe(true)
        expect(#state.queries).toBe(before)
        fx.teardown()
    end)

    it('names the money-as-item accounts in the item census and sends players in full without a change column', function()
        boot({ ox_inventory = 'started' })
        state.extra = ''
        state.queryFn = function(sql, params)
            if sql:find('ox_inventory', 1, true) then return {} end
            if params[#params] ~= '' then return {} end
            return { { identifier = 'char1:a', inventory = '{"water":1}' } }
        end
        run(function() Atlas.snapshots.census('delta') end)
        local list = snapshots('items.census')
        expect(#list > 0).toBe(true)
        for _, ev in ipairs(list) do expect(ev.data.accounts).toEqual({ 'money', 'black_money' }) end
        expect(list[1].data.holder_kind).toBe('player')
        expect(list[1].data.mode).toBe('full')
        expect(list[1].data.since_ts).toBeNil()
        expect(list[1].data.rows[1][2]).toBe('[{"count":1,"name":"water"}]')
        fx.teardown()
    end)

    it('sends the owned vehicle list in pages keyed by plate', function()
        boot()
        state.rows = { { owner = 'char1:a', plate = 'AA', vehicle = '{"model":5}' } }
        state.queryFn = function(_, params)
            if params[1] ~= '' then return {} end
            return state.rows
        end
        run(function() Atlas.snapshots.vehicles() end)
        local pages = snapshots('vehicles.owned')
        expect(#pages).toBe(1)
        expect(pages[1].data.rows[1][1]).toBe('char1:a')
        expect(pages[1].data.final).toBe(true)
        fx.teardown()
    end)

    it('runs full snapshots on the short cycle and online-only deltas in between when rows cannot be found by change', function()
        boot(nil, nil, { ['atlas:token'] = 'atl_live_x', ['atlas:snapshots'] = 1 })
        state.extra = ''
        state.rows = { { identifier = 'char1:a', accounts = '{"bank":20}' } }
        state.queryFn = function(_, params)
            if params[#params] ~= '' then return {} end
            return state.rows
        end
        fx.advance(35000, 1000)
        local modes = {}
        local function collect()
            for _, ev in ipairs(snapshots('money.snapshot')) do modes[#modes + 1] = ev.data.mode end
            fx.state.triggered = {}
        end
        collect()
        expect(modes).toEqual({ 'full' })
        fx.advance(16 * 60000, 5000)
        collect()
        expect(modes).toEqual({ 'full', 'delta' })
        fx.advance(62 * 60000, 5000)
        collect()
        expect(modes[#modes]).toBe('full')
        fx.teardown()
    end)
end)
