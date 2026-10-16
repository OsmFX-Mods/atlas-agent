local fx = load_module('tests/fivem.lua')

local function boot()
    fx.boot({
        convars = { ['atlas:token'] = 'atl_live_x' },
        load = { 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua', 'server/characters.lua', 'server/money.lua' },
    })
    fx.addPlayer(4, { ped = { x = 10.0, y = 10.0, z = 30.0, h = 0.0 } })
    Atlas.ensurePlayer(4)
    Atlas.characters.load(4, { char = 'C1', job = 'police', money = { cash = 100, bank = 500 } })
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

describe('money apply', function()
    it('takes the delta of an add or remove from the amount and keeps the balance', function()
        boot()
        local p = Atlas.players[4]
        expect(Atlas.money.apply(p, 'cash', 'add', 50, 150)).toBe(50)
        expect(p.money.cash).toBe(150)
        expect(Atlas.money.apply(p, 'cash', 'remove', 30, 120)).toBe(-30)
        expect(p.money.cash).toBe(120)
        fx.teardown()
    end)

    it('works out a set as the new balance minus the last known one', function()
        boot()
        local p = Atlas.players[4]
        expect(Atlas.money.apply(p, 'bank', 'set', 900, 900)).toBe(400)
        expect(p.money.bank).toBe(900)
        expect(Atlas.money.apply(p, 'bank', 'set', 100, nil)).toBe(-800)
        fx.teardown()
    end)

    it('has no delta for a set without a known earlier balance', function()
        boot()
        local p = Atlas.players[4]
        expect(Atlas.money.apply(p, 'crypto', 'set', 5, 5)).toBeNil()
        expect(p.money.crypto).toBe(5)
        fx.teardown()
    end)

    it('uses the balance given by the caller as the start of a set', function()
        boot()
        local p = Atlas.players[4]
        expect(Atlas.money.apply(p, 'cash', 'set', 150, 150, 100)).toBe(50)
        fx.teardown()
    end)

    it('keeps the cache when the balance is unknown for an add', function()
        boot()
        local p = Atlas.players[4]
        Atlas.money.apply(p, 'cash', 'add', 5, nil)
        expect(p.money.cash).toBe(100)
        fx.teardown()
    end)

    it('works without a player record', function()
        boot()
        expect(Atlas.money.apply(nil, 'cash', 'add', 5, 5)).toBe(5)
        fx.teardown()
    end)
end)

describe('money change', function()
    it('emits money.change with the delta, balance, reason and paycheck pay', function()
        boot()
        Atlas.players[4].jobPayment = 75
        Atlas.money.change(4, 'cash', 'add', 50, 150, 'sale')
        local ev = events('money.change')[1]
        expect(ev.src).toBe(4)
        expect(ev.data).toEqual({ mtype = 'cash', action = 'add', amount = 50, delta = 50, balance_after = 150, reason = 'sale', job_payment = 75 })
        fx.teardown()
    end)

    it('uses unknown for a missing reason and cuts long ones', function()
        boot()
        Atlas.money.change(4, 'cash', 'add', 1, 101, nil)
        Atlas.money.change(4, 'cash', 'add', 1, 102, ('x'):rep(300))
        local list = events('money.change')
        expect(list[1].data.reason).toBe('unknown')
        expect(#list[2].data.reason).toBe(128)
        fx.teardown()
    end)

    it('records that a selftest change was seen', function()
        boot()
        Atlas.money.change(4, 'cash', 'add', 0, 100, 'atlas_selftest')
        expect(Atlas.selftestMoneySeen).toBe(true)
        fx.teardown()
    end)

    it('stamps a change with the time it happened when one is given', function()
        boot()
        Atlas.money.emit(4, Atlas.players[4], 'cash', 'set', 5, 1, 5, 'x', 12345)
        expect(events('money.change')[1].ts).toBe(12345)
        fx.teardown()
    end)
end)

describe('money flush and live balances', function()
    it('runs every flusher and survives one that fails', function()
        boot()
        local got = {}
        Atlas.money.onFlush(function() error('boom') end)
        Atlas.money.onFlush(function(src) got[#got + 1] = src end)
        Atlas.money.flush(4)
        expect(got).toEqual({ 4 })
        fx.teardown()
    end)

    it('lists the live balances of loaded characters', function()
        boot()
        fx.addPlayer(5, {})
        Atlas.ensurePlayer(5)
        local online = Atlas.onlineBalances()
        expect(online.C1).toEqual({ cash = 100, bank = 500 })
        local n = 0
        for _ in pairs(online) do n = n + 1 end
        expect(n).toBe(1)
        fx.teardown()
    end)
end)
