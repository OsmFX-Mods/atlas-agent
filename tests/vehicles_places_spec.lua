local fx = load_module('tests/fivem.lua')

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

local function hashed(plate) return AtlasLib.common.u32(fx.joaat(plate)) end

describe('qbx_vehicles adapter', function()
    local registered

    local function boot()
        registered = {}
        fx.boot({
            convars = { ['atlas:token'] = 'atl_live_x' }, resources = { qbx_vehicles = 'started' },
            provided = { qbx_vehicles = {
                removeHooks = function() end,
                registerHook = function(_, name, fn) registered[name] = fn end,
            } },
            load = { 'server/db.lua', 'server/adapters/detect.lua', 'server/adapters/qbx_vehicles.lua' },
        })
        fx.advance(200)
    end

    it('emits vehicle.acquire with the model and a hashed plate, never the plate', function()
        boot()
        fx.addPlayer(4, {})
        Atlas.setChar(4, 'CHAR0004', 'Ann')
        expect(registered.createPlayerVehicle({ citizenid = 'CHAR0004', garage = 'legion', props = { model = -1234, plate = '  ab 12 ' } })).toBe(true)
        local ev = events('vehicle.acquire')[1]
        expect(ev.src).toBe(4)
        expect(ev.data.plate_hash).toBe(hashed('AB 12'))
        expect(ev.data.model).toBe(AtlasLib.common.u32(-1234))
        expect(ev.data.owner_char).toBe('CHAR0004')
        expect(ev.data.plate).toBeNil()
        fx.teardown()
    end)

    it('tolerates missing props and malformed payloads', function()
        boot()
        expect(registered.createPlayerVehicle({ citizenid = 'X' })).toBe(true)
        expect(registered.createPlayerVehicle('junk')).toBe(true)
        expect(events('vehicle.acquire')[1].data.plate_hash).toBeNil()
        fx.teardown()
    end)

    it('reads model and plate for a transfer in a thread and stamps the hook time', function()
        boot()
        Atlas.db.available = function() return true end
        Atlas.db.single = function() return { hash = 777, plate = 'xyz 9' } end
        fx.addPlayer(5, {})
        Atlas.setChar(5, 'CHAR0005', 'Bo')
        local at = Atlas.now()
        registered.changeVehicleOwner({ vehicleId = '12', newCitizenId = 'CHAR0005' })
        fx.advance(500)
        local ev = events('vehicle.transfer')[1]
        expect(ev.ts).toBe(at)
        expect(ev.src).toBe(5)
        expect(ev.data.vehicle_id).toBe(12)
        expect(ev.data.model).toBe(777)
        expect(ev.data.plate_hash).toBe(hashed('XYZ 9'))
        fx.teardown()
    end)

    it('still reports a transfer when the database read finds nothing', function()
        boot()
        Atlas.db.single = function() return nil end
        registered.changeVehicleOwner({ vehicleId = 1, newCitizenId = 'CHAR0005' })
        fx.advance(500)
        local ev = events('vehicle.transfer')[1]
        expect(ev.data.model).toBeNil()
        expect(ev.data.to_char).toBe('CHAR0005')
        fx.teardown()
    end)
end)

describe('qbx_ambulancejob check-in hook', function()
    it('emits medical.checkin with the cost read from the resource config', function()
        local registered = {}
        fx.boot({
            convars = { ['atlas:token'] = 'atl_live_x' }, resources = { qbx_ambulancejob = 'started' },
            files = { ['qbx_ambulancejob/config/shared.lua'] = 'return { checkInCost = 250 }' },
            provided = { qbx_ambulancejob = {
                removeHooks = function() end,
                registerHook = function(_, name, fn) registered[name] = fn end,
            } },
            load = { 'server/adapters/detect.lua', 'server/characters.lua', 'server/adapters/qbx_medical.lua' },
        })
        fx.advance(200)
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        expect(registered.checkIn({ source = 4, hospitalName = 'Pillbox' })).toBe(true)
        local ev = events('medical.checkin')[1]
        expect(ev.data).toEqual({ hospital = 'Pillbox', cost = 250 })
        expect(registered.checkIn('junk')).toBe(true)
        fx.teardown()
    end)
end)

describe('Renewed-Banking accounts', function()
    it('classifies accounts using the job and gang names from qbx_core', function()
        fx.boot({
            convars = { ['atlas:token'] = 'atl_live_x' },
            resources = { qbx_core = 'started', ['Renewed-Banking'] = 'started' },
            provided = { qbx_core = {
                GetCoreVersion = function() return '1' end,
                GetPlayer = function() return nil end,
                GetJobs = function() return { police = {} } end,
                GetGangs = function() return { ballas = {} } end,
            } },
            load = {
                'server/db.lua', 'server/sampler.lua', 'server/adapters/detect.lua', 'server/sources.lua',
                'server/framework.lua', 'server/characters.lua', 'server/money.lua', 'server/adapters/natives.lua',
                'server/adapters/qbox_data.lua', 'server/adapters/qbox.lua', 'server/adapters/renewed_banking.lua',
            },
        })
        fx.advance(200)
        Atlas.db.query = function()
            return { { id = 'police', amount = '1500', creator = '' }, { id = 'ballas', amount = 20, creator = nil },
                { id = 'club', amount = 'x', creator = 'CHAR1' }, { id = 'shop', amount = 5, creator = nil } }
        end
        local rows = Atlas.accountsRows()
        expect(rows).toEqual({
            { 'police', 'job', 1500 }, { 'ballas', 'gang', 20 }, { 'club', 'shared', 0 }, { 'shop', 'business', 5 },
        })
        fx.teardown()
    end)

    it('returns an error when the resource is not running or the query fails', function()
        fx.boot({
            convars = { ['atlas:token'] = 'atl_live_x' }, resources = {},
            load = { 'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/adapters/renewed_banking.lua' },
        })
        fx.advance(200)
        local rows, err = Atlas.accountsRows()
        expect(rows).toBeNil()
        expect(err).toBe('no account source started')
        fx.teardown()
    end)
end)

describe('places import', function()
    local function boot(files, provided, resources)
        fx.boot({
            convars = { ['atlas:token'] = 'atl_live_x' }, resources = resources or {}, files = files or {},
            provided = provided or {}, load = {
                'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua',
                'server/adapters/qbox_data.lua', 'server/adapters/ox_inventory_data.lua', 'server/adapters/renewed_banking.lua',
                'server/places.lua',
            },
        })
    end

    it('suggests ox_inventory shops from its data file after the debounce', function()
        boot({ ['ox_inventory/data/shops.lua'] = [[return {
            General = { name = 'Corner Shop', locations = { vec3(25.74, -1347.3, 29.49), vec3(1.0, 2.0, 3.0) } },
            Broken = { name = 'No Coords' },
            Targets = { targets = { { loc = vec3(5.0, 6.0, 7.0) }, 'junk' } },
        } ]] }, nil, { ox_inventory = 'started' })
        fx.tick()
        fx.advance(5000)
        expect(#events('places.suggest')).toBe(0)
        fx.advance(6000)
        local entries = events('places.suggest')[1].data.entries
        local byName = {}
        for _, e in ipairs(entries) do byName[e[1]] = (byName[e[1]] or 0) + 1 end
        expect(byName['Corner Shop']).toBe(2)
        expect(byName['Targets']).toBe(1)
        expect(byName['Broken']).toBeNil()
        for _, e in ipairs(entries) do
            expect(e[2]).toBe('shop')
            expect(e[5]).toBe(15.0)
        end
        fx.teardown()
    end)

    it('uses the place sizes from the config', function()
        boot({ ['ox_inventory/data/shops.lua'] = [[return { General = { name = 'Corner Shop', locations = { vec3(1.0, 2.0, 3.0) } } } ]] },
            nil, { ox_inventory = 'started' })
        AtlasConfig.placeRadius.shop = 22.0
        fx.tick()
        fx.advance(11000)
        expect(events('places.suggest')[1].data.entries[1][5]).toBe(22.0)
        fx.teardown()
    end)

    it('imports garages and hospitals and rounds coordinates', function()
        boot({ ['qbx_ambulancejob/config/shared.lua'] = [[return { locations = { hospitals = {
            pillbox = { coords = vec3(298.66, -584.46, 43.26) } } } } ]] },
            { qbx_garages = { GetGarages = function()
                return { legion = { label = 'Legion', accessPoints = { { coords = { x = 215.8, y = -809.0, z = 30.7 } } } } }
            end } },
            { qbx_garages = 'started', qbx_ambulancejob = 'started' })
        fx.tick()
        fx.advance(11000)
        local entries = events('places.suggest')[1].data.entries
        local kinds = {}
        for _, e in ipairs(entries) do kinds[e[2]] = e end
        expect(kinds.garage[1]).toBe('Legion')
        expect(kinds.garage[5]).toBe(30.0)
        expect(kinds.hospital[1]).toBe('pillbox')
        expect(kinds.hospital[3]).toBe(298.7)
        expect(kinds.hospital[4]).toBe(-584.5)
        fx.teardown()
    end)

    it('runs one import for several resources starting together', function()
        boot({ ['ox_inventory/data/shops.lua'] = 'return { A = { name = "A", locations = { vec3(1.0, 2.0, 3.0) } } }' },
            nil, { ox_inventory = 'started' })
        fx.tick()
        TriggerEvent('onResourceStart', 'ox_inventory')
        TriggerEvent('onResourceStart', 'qbx_garages')
        TriggerEvent('onResourceStart', 'unrelated')
        fx.advance(11000)
        expect(#events('places.suggest')).toBe(1)
        fx.teardown()
    end)

    it('sends nothing when no source resource has places', function()
        boot()
        fx.tick()
        fx.advance(11000)
        expect(#events('places.suggest')).toBe(0)
        fx.teardown()
    end)

    it('splits suggestions into chunks of 500', function()
        boot()
        local list = {}
        for i = 1, 1100 do list[i] = { 'P' .. i, 'custom', 1.0, 2.0, 30.0 } end
        Atlas.suggestPlaces(list)
        local chunks = events('places.suggest')
        expect(#chunks).toBe(3)
        expect(#chunks[3].data.entries).toBe(100)
        fx.teardown()
    end)
end)
