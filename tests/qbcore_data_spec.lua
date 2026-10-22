local fx = load_module('tests/fivem.lua')

local state -- state: tables the fake database has, the rows it returns and the queries it was sent

local function boot(resources, files)
    state = { tables = {}, rows = {}, queries = {}, count = 0 }
    local core = {
        Functions = { GetPlayer = function() return nil end },
        Shared = {
            Jobs = { police = {} }, Gangs = { none = {}, ballas = {} },
            Vehicles = {
                adder = { name = 'Adder', brand = 'Truffade', price = 280000, category = 'super', shop = 'pdm' },
                bmx = { name = 'BMX', price = 160, category = 'cycles', shop = { 'pdm', 'bikes' } },
                broken = { name = 'Broken' },
            },
        },
    }
    local res = { ['qb-core'] = 'started' }
    for k, v in pairs(resources or {}) do res[k] = v end
    fx.boot({
        convars = { ['atlas:token'] = 'atl_live_x', ['atlas:snapshots'] = 0 }, resources = res, files = files or {},
        provided = { ['qb-core'] = { GetCoreObject = function() return core end } },
        load = {
            'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua',
            'server/characters.lua', 'server/staff.lua', 'server/money.lua', 'server/adapters/qb_common.lua', 'server/adapters/qbcore_data.lua',
            'server/adapters/qbcore.lua', 'server/snapshots.lua', 'server/places.lua',
        },
    })
    local db = Atlas.db
    db.available = function() return true end
    db.now = function() return 1790000100.5 end
    db.scalar = function(sql)
        state.queries[#state.queries + 1] = sql
        return state.count
    end
    db.query = function(sql, params)
        state.queries[#state.queries + 1] = sql
        state.lastParams = params
        if sql:find('information_schema', 1, true) then
            if state.schemaErr then return nil, state.schemaErr end
            return state.tables[params[1]] or {}
        end
        if state.queryFn then return state.queryFn(sql, params) end
        return state.rows
    end
    fx.advance(200)
end

local function data() return Atlas.frameworkData.qbcore end

local function last() return state.queries[#state.queries] end

describe('qbcore money reader', function()
    it('decodes the money column and maps money types through the config', function()
        boot()
        state.rows = {
            { citizenid = 'A1', d = '{"cash":10,"bank":200,"crypto":1,"blackmoney":5}' },
            { citizenid = 'B2', d = 'not json' },
            { citizenid = 'C3', d = nil },
        }
        local rows, cursor, got = data().money.page(nil, nil, 2)
        expect(rows).toEqual({ { 'A1', 10, 200, 1 }, { 'B2', 0, 0, 0 }, { 'C3', 0, 0, 0 } })
        expect(cursor).toBe('C3')
        expect(got).toBe(3)
        AtlasConfig.qbcore.moneyTypes.blackmoney = 'cash'
        state.rows = { { citizenid = 'A1', d = '{"cash":10,"blackmoney":5}' } }
        expect(data().money.page(nil, nil, 2)).toEqual({ { 'A1', 15, 0, 0 } })
        fx.teardown()
    end)

    it('reads changed rows only when last_updated updates with the row', function()
        boot()
        state.tables.players = { { c = 'citizenid', e = '' }, { c = 'last_updated', e = 'on update current_timestamp()' } }
        data().money.init()
        expect(data().money.delta).toBe(true)
        data().money.page(1790000000, 'A1', 5)
        expect(last():find('`last_updated` >= FROM_UNIXTIME(?) AND citizenid > ?', 1, true) ~= nil).toBe(true)
        expect(state.lastParams).toEqual({ 1790000000, 'A1' })
        fx.teardown()
        boot()
        state.tables.players = { { c = 'citizenid', e = '' }, { c = 'last_updated', e = '' } }
        data().money.init()
        expect(data().money.delta).toBe(false)
        fx.teardown()
    end)

    it('uses the configured table name and rejects an invalid one', function()
        boot()
        AtlasConfig.qbcore.tables.characters = 'my_players'
        data().money.page(nil, nil, 5)
        expect(last():find('FROM `my_players`', 1, true) ~= nil).toBe(true)
        AtlasConfig.qbcore.tables.characters = 'players; DROP TABLE x'
        expect(data().money.page(nil, nil, 5)).toBeNil()
        expect(#fx.printed('qbcore.tables.characters is not a valid table name')).toBe(1)
        fx.teardown()
    end)
end)

describe('qbcore census', function()
    it('sends player inventories as stored, plus stashes, trunks and gloveboxes from the inventories table', function()
        boot()
        state.tables.inventories = { { c = 'identifier', e = '' }, { c = 'items', e = '' } }
        local kinds = data().census()
        expect(#kinds).toBe(4)
        expect(kinds[1].kind).toBe('player')
        state.rows = { { citizenid = 'A1', d = '[{"name":"water","amount":2,"slot":1}]' } }
        expect(kinds[1].page(nil, nil, 5)[1]).toEqual({ 'A1', '[{"name":"water","amount":2,"slot":1}]' })

        state.rows = { { k = 'trunk- ab 12 ', items = '[{"name":"lockpick","amount":1}]' } }
        local trunk = kinds[3]
        expect(trunk.kind).toBe('trunk')
        local rows = trunk.page(nil, nil, 5)
        expect(rows[1][1]).toBe(tostring(AtlasLib.common.u32(fx.joaat('AB 12'))))
        expect(last():find("identifier LIKE 'trunk-%'", 1, true) ~= nil).toBe(true)
        state.rows = { { k = 'policestash', items = '[]' } }
        expect(kinds[2].page(nil, nil, 5)[1][1]).toBe('policestash')
        expect(last():find("identifier NOT LIKE 'trunk-%' AND identifier NOT LIKE 'glovebox-%'", 1, true) ~= nil).toBe(true)
        fx.teardown()
    end)

    it('reads the older stashitems, trunkitems and gloveboxitems tables when there is no inventories table', function()
        boot()
        state.tables.trunkitems = { { c = 'plate', e = '' }, { c = 'items', e = '' } }
        local trunk = data().census()[3]
        state.rows = { { k = 'XYZ789', items = '[]' } }
        local rows = trunk.page(nil, nil, 5)
        expect(rows[1][1]).toBe(tostring(AtlasLib.common.u32(fx.joaat('XYZ789'))))
        expect(last():find('FROM `trunkitems`', 1, true) ~= nil).toBe(true)
        fx.teardown()
    end)

    it('counts a missing table as empty and fails a page only on a database error', function()
        boot()
        local stash = data().census()[2]
        local rows, cursor, got = stash.page(nil, nil, 5)
        expect(rows).toEqual({})
        expect(cursor).toBeNil()
        expect(got).toBe(0)
        expect(stash.count()).toBe(0)
        fx.teardown()
        boot()
        state.schemaErr = 'timeout'
        expect(data().census()[2].page(nil, nil, 5)).toBeNil()
        fx.teardown()
    end)
end)

describe('qbcore groups, prices and accounts', function()
    it('lists jobs and gangs from the shared tables, leaving out the none gang', function()
        boot()
        local jobs, gangs = Atlas.groups()
        expect(jobs).toEqual({ police = true })
        expect(gangs).toEqual({ ballas = true })
        fx.teardown()
    end)

    it('sends vehicle prices from the shared vehicles', function()
        boot()
        Atlas.pricesCatalog()
        Atlas.jsReady = true
        Atlas.flush()
        local found
        for _, call in ipairs(fx.triggered('atlas:internal:batch')) do
            for _, ev in ipairs(call[1]) do
                if ev.type == 'prices.catalog' and ev.data.kind == 'vehicle' then found = ev.data.entries end
            end
        end
        expect(found).toEqual({ { 'adder', 'Truffade Adder', 280000, 'pdm', 'super' }, { 'bmx', 'BMX', 160, 'pdm', 'cycles' } })
        fx.teardown()
    end)

    it('reads qb-banking accounts with their kind', function()
        boot({ ['qb-banking'] = 'started' })
        state.rows = {
            { account_name = 'police', account_balance = 5000, account_type = 'job' },
            { account_name = 'ballas', account_balance = 200, account_type = 'gang' },
            { account_name = 'Joint', account_balance = '15', account_type = 'shared' },
        }
        local rows = Atlas.accountsRows()
        expect(rows).toEqual({ { 'police', 'job', 5000 }, { 'ballas', 'gang', 200 }, { 'Joint', 'shared', 15 } })
        fx.teardown()
    end)

    it('reads the older qb-management funds only while qb-banking is not running', function()
        boot({ ['qb-management'] = 'started' })
        state.tables.management_funds = { { c = 'job_name', e = '' } }
        state.rows = { { job_name = 'police', amount = 900, type = 'boss' }, { job_name = 'ballas', amount = 50, type = 'gang' } }
        expect(Atlas.accountsRows()).toEqual({ { 'police', 'job', 900 }, { 'ballas', 'gang', 50 } })
        fx.teardown()
        boot({ ['qb-management'] = 'started' })
        expect(Atlas.accountsRows()).toEqual({})
        fx.teardown()
    end)
end)

describe('qbcore places', function()
    local files = {
        ['qb-garages/config.lua'] = [[Config = {}
            Config.Garages = { motelgarage = { label = 'Motel Parking', takeVehicle = vector3(274.0, -334.0, 44.0) } }]],
        ['qb-policejob/config.lua'] = [[Config = {}
            Config.Locations = { stations = { { label = 'Police Station', coords = vector4(428.0, -984.0, 29.0, 3.5) } } }]],
        ['qb-ambulancejob/config.lua'] = [[Config = {}
            Config.Locations = { ['hospital'] = { { ['name'] = Lang:t('info.pb_hospital'), ['location'] = vector3(308.0, -595.0, 43.0) } } }]],
        ['qb-ambulancejob/locales/en.lua'] = [[local Translations = { info = { pb_hospital = 'Pillbox Hospital' } }
            Lang = Lang or Locale:new({ phrases = Translations, warnOnMissing = true })]],
        ['qb-shops/config.lua'] = [[Config = {}
            Config.UseTarget = GetConvar('UseTarget', 'false') == 'true'
            Config.Products = { normal = { { name = 'water_bottle', price = 2, amount = 50 } } }
            Config.Locations = {
                ['247supermarket'] = { label = '24/7 Supermarket', coords = vector4(24.0, -1346.0, 29.0, 271.0), products = Config.Products.normal },
                ['oldshop'] = { label = 'Old Shop', coords = { vector3(1.0, 2.0, 3.0), vector3(4.0, 5.0, 6.0) }, products = Config.Products.normal },
            }]],
    }

    it('reads garages, hospitals with their English names, police stations and shops', function()
        boot({ ['qb-garages'] = 'started', ['qb-policejob'] = 'started', ['qb-ambulancejob'] = 'started', ['qb-shops'] = 'started' }, files)
        local added = {}
        for _, def in ipairs(Atlas.sources('places')) do
            def.read(function(name, kind, pos) added[#added + 1] = { name = name, kind = kind, x = pos and pos.x } end)
        end
        local byName = {}
        for _, a in ipairs(added) do byName[a.name] = (byName[a.name] or 0) + 1 end
        expect(byName['Motel Parking']).toBe(1)
        expect(byName['Police Station']).toBe(1)
        expect(byName['Pillbox Hospital']).toBe(1)
        expect(byName['24/7 Supermarket']).toBe(1)
        expect(byName['Old Shop']).toBe(2)
        fx.teardown()
    end)

    it('sends shop item prices once per shop', function()
        boot({ ['qb-shops'] = 'started' }, files)
        local got
        for _, def in ipairs(Atlas.sources('prices')) do
            if def.name == 'qb-shops' then def.read(function(kind, entries) got = { kind, entries } end) end
        end
        expect(got[1]).toBe('item')
        expect(got[2]).toEqual({ { 'water_bottle', '', 2, '247supermarket' }, { 'water_bottle', '', 2, 'oldshop' } })
        fx.teardown()
    end)
end)
