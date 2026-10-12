local fx = load_module('tests/fivem.lua')

local hooks, removed, items

local function boot(convars)
    convars = convars or {}
    convars['atlas:token'] = 'atl_live_x'
    hooks, removed, items = {}, 0, {}
    local ox = {
        removeHooks = function() removed = removed + 1 end,
        registerHook = function(_, name, fn, opts) hooks[name] = { fn = fn, opts = opts } end,
        Items = function() return items end,
    }
    fx.boot({
        convars = convars, resources = { ox_inventory = 'started' }, provided = { ox_inventory = ox },
        load = { 'server/adapters/detect.lua', 'server/adapters/ox_inventory.lua' },
    })
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

local function online(src, char)
    fx.addPlayer(src, {})
    Atlas.ensurePlayer(src)
    if char then Atlas.setChar(src, char, char) end
end

describe('ox_inventory hooks', function()
    it('registers the hooks it needs and clears older ones first', function()
        boot()
        expect(removed).toBe(1)
        for _, name in ipairs({ 'swapItems', 'buyItem', 'craftItem', 'usingItem', 'openShop', 'openInventory' }) do
            expect(hooks[name] ~= nil).toBe(true)
        end
        expect(hooks.createItem).toBeNil()
        expect(hooks.openInventory.opts.typeFilter).toEqual({ stash = true })
        fx.teardown()
    end)

    it('registers createItem only when enabled and skips shop visits when switched off', function()
        boot({ ['atlas:ox_createitem'] = 1, ['atlas:place_visits'] = 0 })
        expect(hooks.createItem ~= nil).toBe(true)
        expect(hooks.openShop).toBeNil()
        expect(hooks.openInventory).toBeNil()
        fx.teardown()
    end)

    it('turns a swap into item.move events and lets the action through', function()
        boot()
        online(1, 'CHAR0001')
        local allowed = hooks.swapItems.fn({
            source = 1, fromInventory = 1, toInventory = 'motel_1', fromType = 'player', toType = 'stash',
            fromSlot = { name = 'water', count = 3 }, count = 2, action = 'move',
        })
        expect(allowed).toBe(true)
        local ev = events('item.move')[1]
        expect(ev.src).toBe(1)
        expect(ev.data.from.id).toBe('CHAR0001')
        expect(ev.data.to).toEqual({ kind = 'stash', id = 'motel_1' })
        fx.teardown()
    end)

    it('still allows the action when building the event fails', function()
        boot()
        online(1)
        local emit = Atlas.emit
        Atlas.emit = function() error('boom') end
        local allowed = hooks.buyItem.fn({ source = 1, itemName = 'water', count = 1, price = 5, shopType = 'General' })
        Atlas.emit = emit
        expect(allowed).toBe(true)
        expect(Atlas.drops.ox_hook_error).toBe(1)
        fx.teardown()
    end)

    it('passes straight through while disabled', function()
        boot()
        Atlas.enabled = false
        expect(hooks.swapItems.fn({})).toBe(true)
        expect(Atlas.lastSeq()).toBe(0)
        fx.teardown()
    end)

    it('records purchases, crafting and item use', function()
        boot()
        online(1)
        hooks.buyItem.fn({ source = 1, itemName = 'water', count = 2, price = 5, shopType = 'General', shopId = 3 })
        hooks.craftItem.fn({ source = 1, benchId = 'b1', recipe = { name = 'lockpick', ingredients = { scrap = 2 } } })
        hooks.usingItem.fn({ source = 1, item = { name = 'bandage' }, consume = 0.5 })
        hooks.usingItem.fn({ source = 1, item = {} })
        expect(events('item.buy')[1].data.shop).toBe('General:3')
        expect(events('item.craft')[1].data.recipe).toBe('b1:lockpick')
        local use = events('item.use')
        expect(#use).toBe(1)
        expect(use[1].data).toEqual({ item = 'bandage', count = 0.5 })
        fx.teardown()
    end)

    it('records item creation for players and skips money items', function()
        boot({ ['atlas:ox_createitem'] = 1 })
        online(1, 'CHAR0001')
        hooks.createItem.fn({ item = { name = 'water' }, inventoryId = 1, count = 2 })
        hooks.createItem.fn({ item = { name = 'money' }, inventoryId = 1, count = 500 })
        local ev = events('item.create')
        expect(#ev).toBe(1)
        expect(ev[1].data.to).toEqual({ kind = 'player', id = 'CHAR0001' })
        expect(ev[1].src).toBe(1)
        fx.teardown()
    end)

    it('records shop and stash visits as place.visit', function()
        boot()
        online(1)
        hooks.openShop.fn({ source = 1, shopType = 'General', shopId = 2 })
        hooks.openInventory.fn({ source = 1, inventoryId = 'police_locker' })
        local ev = events('place.visit')
        expect(ev[1].data).toEqual({ place_ref = 'shop:General:2', kind = 'shop' })
        expect(ev[2].data).toEqual({ place_ref = 'stash:police_locker', kind = 'stash' })
        fx.teardown()
    end)

    it('sends the item catalog sorted, with the name as label when none is set', function()
        boot()
        fx.teardown()
        hooks, removed = {}, 0
        items = { water = { label = 'Water', weight = 100 }, bread = { weight = 'x' }, [5] = {}, junk = 'no' }
        fx.boot({
            convars = { ['atlas:token'] = 'atl_live_x' }, resources = { ox_inventory = 'started' },
            provided = { ox_inventory = { removeHooks = function() end, registerHook = function() end, Items = function() return items end } },
            load = { 'server/adapters/detect.lua', 'server/adapters/ox_inventory.lua' },
        })
        fx.advance(200)
        local entries = events('items.catalog')[1].data.entries
        expect(entries).toEqual({ { 'bread', 'bread', 0 }, { 'water', 'Water', 100 } })
        fx.teardown()
    end)

    it('splits a large catalog into chunks of 500', function()
        boot()
        fx.teardown()
        local big = {}
        for i = 1, 1200 do big['item' .. i] = { label = 'I' .. i, weight = 1 } end
        fx.boot({
            convars = { ['atlas:token'] = 'atl_live_x' }, resources = { ox_inventory = 'started' },
            provided = { ox_inventory = { removeHooks = function() end, registerHook = function() end, Items = function() return big end } },
            load = { 'server/adapters/detect.lua', 'server/adapters/ox_inventory.lua' },
        })
        fx.advance(200)
        local chunks = events('items.catalog')
        expect(#chunks).toBe(3)
        expect(#chunks[1].data.entries).toBe(500)
        expect(#chunks[3].data.entries).toBe(200)
        fx.teardown()
    end)
end)
