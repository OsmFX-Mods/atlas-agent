local fx = load_module('tests/fivem.lua')

local listeners -- listeners: callbacks the fake qb-inventory holds, by event

local function boot(opts)
    opts = opts or {}
    listeners = {}
    local core = {
        Functions = { GetPlayer = function() return nil end },
        Shared = { Jobs = {}, Gangs = {}, Items = { water = { label = 'Water', weight = 500 } } },
    }
    local inv = {
        AddListener = function(_, event, fn)
            if opts.old then error('No such export AddListener in resource qb-inventory') end
            listeners[event] = fn
            return 1
        end,
        RemoveListener = function(_, event) listeners[event] = nil end,
    }
    fx.boot({
        convars = opts.convars or { ['atlas:token'] = 'atl_live_x' },
        resources = { ['qb-core'] = 'started', ['qb-inventory'] = 'started' },
        provided = { ['qb-core'] = { GetCoreObject = function() return core end, GetShared = function() return core.Shared.Items end }, ['qb-inventory'] = inv },
        load = {
            'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua',
            'server/characters.lua', 'server/staff.lua', 'server/money.lua', 'server/adapters/qb_common.lua', 'server/adapters/qbcore_data.lua',
            'server/adapters/qbcore.lua', 'server/adapters/qb_inventory.lua',
        },
    })
    Atlas.db.available = function() return false end
    fx.advance(1500)
    for _, src in ipairs({ 4, 5 }) do
        fx.addPlayer(src, {})
        Atlas.ensurePlayer(src)
        Atlas.setChar(src, 'CID' .. src, 'P' .. src)
    end
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

local function plateId(plate) return tostring(AtlasLib.common.u32(fx.joaat(plate))) end

describe('qb-inventory adapter', function()
    it('sends a move from the player to a trunk with the plate hashed', function()
        boot()
        listeners.ItemMoved('moved', {
            fromType = 'player', toType = 'trunk', fromId = 4, toId = 'trunk-AB12', fromSlot = 1, toSlot = 3, amount = 2,
            toInventory = { items = { [3] = { name = 'water', amount = 2 } } },
        })
        local ev = events('item.move')[1]
        expect(ev.src).toBe(4)
        expect(ev.data).toEqual({ item = 'water', count = 2, from = { kind = 'player', id = 'CID4' }, to = { kind = 'trunk', id = plateId('AB12') }, action = 'move' })
        fx.teardown()
    end)

    it('sends both items of a swap and names a stash by its name', function()
        boot()
        listeners.ItemMoved('swapped', {
            fromType = 'player', toType = 'inventory', fromId = 4, toId = 'policestash', fromSlot = 1, toSlot = 2, amount = 1,
            fromInventory = { items = { [1] = { name = 'bread', amount = 3 } } },
            toInventory = { items = { [2] = { name = 'water', amount = 5 } } },
        })
        local moves = events('item.move')
        expect(#moves).toBe(2)
        expect(moves[1].data.count).toBe(5)
        expect(moves[1].data.to).toEqual({ kind = 'stash', id = 'policestash' })
        expect(moves[2].data).toEqual({ item = 'bread', count = 3, from = { kind = 'stash', id = 'policestash' }, to = { kind = 'player', id = 'CID4' }, action = 'swap' })
        fx.teardown()
    end)

    it('sends a give from the removal, which names the item and the receiving player', function()
        boot()
        listeners.ItemMoved('given', { fromType = 'player', toType = 'player', fromId = 4, toId = 5, fromSlot = 1, amount = 1 })
        listeners.ItemRemoved('item', { fromId = 4, fromType = 'player', item = { name = 'water', amount = 1 }, amount = 1, reason = 'Item given to ID #5' })
        listeners.ItemRemoved('item', { fromId = 4, fromType = 'player', item = { name = 'water', amount = 1 }, amount = 1, reason = 'dropped item' })
        local moves = events('item.move')
        expect(#moves).toBe(1)
        expect(moves[1].data).toEqual({
            item = 'water', count = 1, from = { kind = 'player', id = 'CID4' }, to = { kind = 'player', id = 'CID5' },
            action = 'give', counterparty_char = 'CID5',
        })
        fx.teardown()
    end)

    it('sends drops, pickups, uses and purchases', function()
        boot()
        listeners.ItemDropped('item', { source = 4, item = { name = 'water', amount = 2 }, amount = 2 })
        listeners.ItemMoved('moved', {
            fromType = 'drop', toType = 'player', fromId = 'drop-55', toId = 4, fromSlot = 1, toSlot = 1, amount = 1,
            toInventory = { items = { [1] = { name = 'water', amount = 1 } } },
        })
        listeners.ItemUsed('item', { source = 4, item = { name = 'water' } })
        listeners.ItemBought('normal', { shop = { name = '247supermarket' }, toId = 4, item = { name = 'water', price = 2 }, amount = 3, totalPrice = 6 })
        local moves = events('item.move')
        expect(moves[1].data.action).toBe('drop')
        expect(moves[2].data.action).toBe('pickup')
        expect(moves[2].data.from).toEqual({ kind = 'drop', id = 'drop-55' })
        expect(events('item.use')[1].data).toEqual({ item = 'water', count = 1 })
        expect(events('item.buy')[1].data).toEqual({ item = 'water', count = 3, shop = '247supermarket', price_each = 2, currency = 'money' })
        fx.teardown()
    end)

    it('sends shop and stash visits', function()
        boot()
        listeners.ShopOpened('normal', { source = 4, shop = { name = '247supermarket' } })
        listeners.InventoryOpened('inventory', { source = 4, inventoryId = 'policestash' })
        listeners.InventoryOpened('player', { source = 4, inventoryId = 5 })
        local visits = events('place.visit')
        expect(#visits).toBe(2)
        expect(visits[1].data).toEqual({ place_ref = 'shop:247supermarket', kind = 'shop' })
        expect(visits[2].data).toEqual({ place_ref = 'stash:policestash', kind = 'stash' })
        fx.teardown()
    end)

    it('listens to item additions only when enabled, leaving out purchases and gives', function()
        boot()
        expect(listeners.ItemAdded).toBeNil()
        fx.teardown()
        boot({ convars = { ['atlas:token'] = 'atl_live_x', ['atlas:qb_createitem'] = 1 } })
        listeners.ItemAdded('item', { toId = 4, toType = 'player', item = { name = 'water' }, amount = 2, reason = 'job reward' })
        listeners.ItemAdded('item', { toId = 4, toType = 'player', item = { name = 'water' }, amount = 1, reason = 'shop-purchase' })
        listeners.ItemAdded('item', { toId = 4, toType = 'player', item = { name = 'water' }, amount = 1, reason = 'Item given from ID #5' })
        local created = events('item.create')
        expect(#created).toBe(1)
        expect(created[1].data).toEqual({ item = 'water', count = 2, to = { kind = 'player', id = 'CID4' } })
        fx.teardown()
    end)

    it('sends the items catalog from the shared items', function()
        boot()
        expect(events('items.catalog')[1].data.entries).toEqual({ { 'water', 'Water', 500 } })
        fx.teardown()
    end)

    it('attaches without item events on versions that have no listeners', function()
        boot({ old = true })
        expect(Atlas.adapterActive('qb_inventory')).toBe(true)
        expect(#fx.printed('qb-inventory has no listeners in this version')).toBe(1)
        fx.teardown()
    end)
end)
