local inv = load_module('server/lib/inventory.lua')

local chars = { [1] = 'ABC11111', [2] = 'XYZ22222' }
local charOf = function(src) return chars[src] end

describe('inventory.mapSwap', function()
    it('ignores slot rearranging inside one inventory', function()
        expect(inv.mapSwap({ source = 1, fromInventory = 1, toInventory = 1, fromType = 'player', toType = 'player',
            fromSlot = { name = 'water', count = 2 }, count = 1, action = 'move' }, charOf)).toBeNil()
    end)

    it('maps player -> stash moves', function()
        local m = inv.mapSwap({ source = 1, fromInventory = 1, toInventory = 'motel_12', fromType = 'player', toType = 'stash',
            fromSlot = { name = 'water', count = 5 }, toSlot = 3, count = 2, action = 'move' }, charOf)
        expect(#m).toBe(1)
        expect(m[1].item).toBe('water')
        expect(m[1].count).toBe(2)
        expect(m[1].from).toEqual({ kind = 'player', id = 'ABC11111' })
        expect(m[1].to).toEqual({ kind = 'stash', id = 'motel_12' })
        expect(m[1].action).toBe('move')
        expect(m[1].counterparty_char).toBeNil()
    end)

    it('maps gives with the counterparty character', function()
        local m = inv.mapSwap({ source = 1, fromInventory = 1, toInventory = 2, fromType = 'player', toType = 'player',
            fromSlot = { name = 'lockpick', count = 3 }, count = 1, action = 'give' }, charOf)
        expect(m[1].action).toBe('give')
        expect(m[1].counterparty_char).toBe('XYZ22222')
        expect(m[1].to.id).toBe('XYZ22222')
    end)

    it('maps drops (newdrop gets its drop id) and pickups', function()
        local d = inv.mapSwap({ source = 1, fromInventory = 1, toInventory = 'newdrop', fromType = 'player', toType = 'drop',
            fromSlot = { name = 'bread', count = 1 }, count = 1, action = 'move', dropId = 'drop-77' }, charOf)
        expect(d[1].action).toBe('drop')
        expect(d[1].to).toEqual({ kind = 'drop', id = 'drop-77' })
        local p = inv.mapSwap({ source = 1, fromInventory = 'drop-77', toInventory = 1, fromType = 'drop', toType = 'player',
            fromSlot = { name = 'bread', count = 1 }, count = 1, action = 'move' }, charOf)
        expect(p[1].action).toBe('pickup')
    end)

    it('emits both directions for a swap', function()
        local m = inv.mapSwap({ source = 1, fromInventory = 1, toInventory = 'trunkABC', fromType = 'player', toType = 'trunk',
            fromSlot = { name = 'water', count = 4 }, toSlot = { name = 'bandage', count = 2 }, count = 1, action = 'swap' }, charOf)
        expect(#m).toBe(2)
        expect(m[1].count).toBe(4)
        expect(m[2].item).toBe('bandage')
        expect(m[2].from.kind).toBe('trunk')
        expect(m[2].to.id).toBe('ABC11111')
    end)

    it('maps "stack" to move', function()
        local m = inv.mapSwap({ source = 1, fromInventory = 'glovePLATE', toInventory = 1, fromType = 'glovebox', toType = 'player',
            fromSlot = { name = 'water', count = 4 }, toSlot = { name = 'water', count = 1 }, count = 4, action = 'stack' }, charOf)
        expect(#m).toBe(1)
        expect(m[1].action).toBe('move')
    end)

    it('rejects garbage', function()
        expect(inv.mapSwap(nil, charOf)).toBeNil()
        expect(inv.mapSwap({ fromInventory = 1, toInventory = 2, fromSlot = 5 }, charOf)).toBeNil()
    end)
end)

describe('inventory buy/craft/kind', function()
    it('maps buyItem', function()
        local b = inv.mapBuy({ source = 1, shopType = 'General', shopId = 1, itemName = 'water', count = 3, price = 10, totalPrice = 30, currency = 'money' })
        expect(b).toEqual({ item = 'water', count = 3, shop = 'General:1', price_each = 10, currency = 'money' })
    end)

    it('maps craftItem with sorted ingredients', function()
        local c = inv.mapCraft({ benchId = 'bench1', recipe = { name = 'lockpick', count = 2, ingredients = { scrapmetal = 5, garbage = 0.1 } } })
        expect(c.recipe).toBe('bench1:lockpick')
        expect(c.out).toEqual({ { 'lockpick', 2 } })
        expect(c['in']).toEqual({ { 'garbage', 0.1 }, { 'scrapmetal', 5 } })
    end)

    it('guesses holder kind from an inventory id', function()
        expect(inv.kindFromId(3)).toBe('player')
        expect(inv.kindFromId('trunkABC 123')).toBe('trunk')
        expect(inv.kindFromId('gloveXYZ')).toBe('glovebox')
        expect(inv.kindFromId('drop-4')).toBe('drop')
        expect(inv.kindFromId('police_locker')).toBe('stash')
        expect(inv.kind('policeevidence')).toBe('stash')
        expect(inv.kind('newdrop')).toBe('drop')
    end)
end)

describe('inventory.census', function()
    local json = {
        decode = function(s)
            if s == '{"water":2,"bread":1,"none":0}' then return { water = 2, bread = 1, none = 0 } end
            if s == '{"1":{"name":"water"}}' then return { ['1'] = { name = 'water' } } end
            if s == '{}' then return {} end
            error('bad json')
        end,
        encode = function(list)
            local parts = {}
            for i, it in ipairs(list) do parts[i] = it.name .. ':' .. it.count end
            return table.concat(parts, ',')
        end,
    }

    it('turns a name to count table into a sorted list without empty entries', function()
        expect(inv.census('{"water":2,"bread":1,"none":0}', json)).toBe('bread:1,water:2')
    end)

    it('leaves lists and slot tables as stored', function()
        expect(inv.census('[{"name":"water","count":1}]', json)).toBe('[{"name":"water","count":1}]')
        expect(inv.census('{"1":{"name":"water"}}', json)).toBe('{"1":{"name":"water"}}')
    end)

    it('sends an empty list for missing, empty or broken data', function()
        expect(inv.census(nil, json)).toBe('[]')
        expect(inv.census('', json)).toBe('[]')
        expect(inv.census('{broken', json)).toBe('[]')
    end)
end)
