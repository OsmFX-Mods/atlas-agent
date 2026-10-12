local fx = load_module('tests/fivem.lua')

local function boot(convars)
    convars = convars or {}
    convars['atlas:token'] = 'atl_live_x'
    fx.boot({ convars = convars, load = { 'server/sampler.lua' } })
    fx.tick()
end

local function join(src, ped)
    fx.addPlayer(src, { ped = ped })
    return Atlas.ensurePlayer(src)
end

local function drain()
    Atlas.jsReady = true
    Atlas.flush()
    local out = {}
    for _, call in ipairs(fx.triggered('atlas:internal:batch')) do
        for _, ev in ipairs(call[1]) do out[#out + 1] = ev end
    end
    fx.state.triggered = {}
    return out
end

local function ofType(events, etype, src)
    local out = {}
    for _, ev in ipairs(events) do
        if ev.type == etype and (not src or ev.src == src) then out[#out + 1] = ev end
    end
    return out
end

local function walker(x, y)
    return { x = x, y = y, z = 30.0, h = 0.0 }
end

describe('sampler schedule', function()
    it('samples a walking player once per sample_ms, not once per slice', function()
        boot()
        local ped = walker(0.0, 0.0)
        join(1, ped)
        for _ = 1, 30 do
            fx.advance(1000)
            ped.x = ped.x + 5.0
        end
        local samples = ofType(drain(), 'position.sample', 1)
        -- Interval: 30 s at the default 3 s is 10 samples, with one more allowed for the first read
        expect(#samples >= 9 and #samples <= 11).toBe(true)
        fx.teardown()
    end)

    it('keeps each player on the sample_ms interval on a small busy server', function()
        boot()
        local peds = {}
        for src = 1, 5 do
            peds[src] = walker(src * 100.0, 0.0)
            join(src, peds[src])
        end
        for _ = 1, 30 do
            fx.advance(1000)
            for _, p in ipairs(peds) do p.x = p.x + 5.0 end
        end
        local events = drain()
        for src = 1, 5 do
            local n = #ofType(events, 'position.sample', src)
            expect(n >= 9 and n <= 11).toBe(true)
        end
        fx.teardown()
    end)

    it('respects a custom atlas:sample_ms', function()
        boot({ ['atlas:sample_ms'] = 6000 })
        local ped = walker(0.0, 0.0)
        join(1, ped)
        for _ = 1, 30 do
            fx.advance(1000)
            ped.x = ped.x + 5.0
        end
        local n = #ofType(drain(), 'position.sample', 1)
        expect(n >= 4 and n <= 6).toBe(true)
        fx.teardown()
    end)

    it('skips a ped that is not placed yet', function()
        boot()
        join(1, walker(0.0, 0.0))
        fx.advance(5000)
        expect(#ofType(drain(), 'position.sample')).toBe(0)
        expect(Atlas.stats.samples).toBe(0)
        fx.teardown()
    end)

    it('does nothing while the agent is disabled', function()
        boot()
        join(1, walker(10.0, 10.0))
        Atlas.enabled = false
        fx.advance(5000)
        expect(Atlas.stats.samples).toBe(0)
        fx.teardown()
    end)
end)

describe('sampler output', function()
    it('rounds the position and records heading, speed, health and precision', function()
        boot()
        local ped = { x = 10.04, y = 20.06, z = 5.55, h = 89.6, hp = 150, vel = { x = 3.0, y = 4.0, z = 0.0 } }
        join(1, ped)
        fx.advance(200)
        local s = ofType(drain(), 'position.sample', 1)[1]
        expect(s ~= nil).toBe(true)
        expect(s.data.h).toBe(90)
        expect(s.data.spd).toBe(5.0)
        expect(s.data.hp).toBe(150)
        expect(s.data.precision).toBe('normal')
        expect(s.data.veh).toBeNil()
        expect(s.pos).toEqual({ 10.0, 20.1, 5.6 })
        fx.teardown()
    end)

    it('records the vehicle model, type and seat', function()
        boot()
        local ped = walker(1.0, 1.0)
        ped.vehicle = { model = -1234, vtype = 'automobile', driver = true }
        join(1, ped)
        fx.advance(200)
        local s = ofType(drain(), 'position.sample', 1)[1]
        expect(s.data.veh).toEqual({ model = AtlasLib.common.u32(-1234), vtype = 'automobile', seat = 'driver' })
        fx.teardown()
    end)

    it('sends position.still instead of repeating samples for a standing player', function()
        boot()
        join(1, walker(50.0, 50.0))
        fx.advance(62000)
        local events = drain()
        expect(#ofType(events, 'position.sample', 1)).toBe(1)
        local still = ofType(events, 'position.still', 1)
        expect(#still >= 1 and #still <= 3).toBe(true)
        fx.teardown()
    end)

    it('emits a bucket change once and updates the actor', function()
        boot()
        join(1, walker(5.0, 5.0))
        fx.advance(200)
        fx.state.players[1].bucket = 9
        fx.advance(4000)
        local events = drain()
        local b = ofType(events, 'bucket.change', 1)
        expect(#b).toBe(1)
        expect(b[1].data).toEqual({ from = 0, to = 9 })
        expect(Atlas.players[1].actor.bucket).toBe(9)
        fx.teardown()
    end)

    it('timestamps samples with the wall clock, not the game timer', function()
        boot()
        join(1, walker(5.0, 5.0))
        fx.advance(200)
        local s = ofType(drain(), 'position.sample', 1)[1]
        expect(math.abs(s.ts - os.time() * 1000) < 2000).toBe(true)
        fx.teardown()
    end)
end)

describe('sampler weapons and positions', function()
    it('records the equipped weapon except unarmed', function()
        boot()
        local ped = walker(5.0, 5.0)
        ped.weapon = 453432689
        local p = join(1, ped)
        fx.advance(200)
        expect(p.weapons[453432689] ~= nil).toBe(true)
        ped.weapon = fx.joaat('WEAPON_UNARMED')
        ped.x = 99.0
        fx.advance(4000)
        expect(p.weapons[AtlasLib.common.u32(fx.joaat('WEAPON_UNARMED'))]).toBeNil()
        fx.teardown()
    end)

    it('keeps at most 24 recent positions, oldest replaced first', function()
        boot()
        local ped = walker(0.0, 0.0)
        local p = join(1, ped)
        for _ = 1, 120 do
            fx.advance(1000)
            ped.x = ped.x + 3.0
        end
        local recent = Atlas.recentPositions(p)
        expect(#recent).toBe(24)
        local minX, maxX = math.huge, 0
        for _, r in ipairs(recent) do minX, maxX = math.min(minX, r[1]), math.max(maxX, r[1]) end
        -- Window: 24 entries 3 s apart cover the last ~72 s of a 120 s walk, so early positions are gone
        expect(minX > 120.0).toBe(true)
        expect(maxX >= 340.0).toBe(true)
        fx.teardown()
    end)

    it('keeps the ring spanning the report window while boosted samples arrive every second', function()
        boot()
        local ped = walker(0.0, 0.0)
        local p = join(1, ped)
        fx.advance(200)
        for _ = 1, 70 do
            Atlas.boost(ped.x, ped.y)
            fx.advance(1000)
            ped.x = ped.x + 3.0
        end
        local recent = Atlas.recentPositions(p)
        local minX = math.huge
        for _, r in ipairs(recent) do minX = math.min(minX, r[1]) end
        -- Span: positions from 60 s ago (x about 30) are still present
        expect(minX <= 30.0).toBe(true)
        fx.teardown()
    end)

    it('forgets sampler state when a player drops', function()
        boot()
        local p = join(1, walker(5.0, 5.0))
        fx.advance(200)
        expect(Atlas.sampler.state[1] ~= nil).toBe(true)
        Atlas.runDrop(p, 'quit')
        expect(Atlas.sampler.state[1]).toBeNil()
        fx.teardown()
    end)
end)

describe('sampler combat boost', function()
    it('boosts only players within the radius', function()
        boot()
        join(1, walker(10.0, 10.0)); join(2, walker(110.0, 10.0)); join(3, walker(410.0, 10.0))
        fx.advance(500)
        Atlas.boost(10.0, 10.0)
        expect(Atlas.sampler.boostUntil[1] ~= nil).toBe(true)
        expect(Atlas.sampler.boostUntil[2] ~= nil).toBe(true)
        expect(Atlas.sampler.boostUntil[3]).toBeNil()
        fx.teardown()
    end)

    it('samples boosted players every second with high precision', function()
        boot()
        local ped = walker(10.0, 10.0)
        join(1, ped)
        fx.advance(200)
        drain()
        Atlas.boost(10.0, 10.0)
        for _ = 1, 10 do
            fx.advance(1000)
            ped.x = ped.x + 5.0
        end
        local s = ofType(drain(), 'position.sample', 1)
        expect(#s >= 9).toBe(true)
        for _, ev in ipairs(s) do expect(ev.data.precision).toBe('high') end
        fx.teardown()
    end)

    it('leaves boosted players to the boost pass even when sample_ms is shorter than a second', function()
        boot({ ['atlas:sample_ms'] = 500 })
        local ped = walker(10.0, 10.0)
        join(1, ped)
        fx.advance(200)
        Atlas.boost(10.0, 10.0)
        drain()
        for _ = 1, 6 do
            fx.advance(1000)
            ped.x = ped.x + 5.0
        end
        local s = ofType(drain(), 'position.sample', 1)
        expect(#s >= 5 and #s <= 7).toBe(true)
        for _, ev in ipairs(s) do expect(ev.data.precision).toBe('high') end
        fx.teardown()
    end)

    it('returns to the normal interval after the boost ends', function()
        boot()
        local ped = walker(10.0, 10.0)
        join(1, ped)
        fx.advance(200)
        Atlas.boost(10.0, 10.0)
        fx.advance(AtlasConfig.boostMs + 2000, 500)
        drain()
        for _ = 1, 30 do
            fx.advance(1000)
            ped.x = ped.x + 5.0
        end
        local s = ofType(drain(), 'position.sample', 1)
        expect(#s >= 9 and #s <= 11).toBe(true)
        expect(s[#s].data.precision).toBe('normal')
        fx.teardown()
    end)

    it('does nothing when combat boost is switched off', function()
        boot({ ['atlas:combat_boost'] = 0 })
        join(1, walker(10.0, 10.0))
        fx.advance(200)
        Atlas.boost(10.0, 10.0)
        expect(next(Atlas.sampler.boostUntil)).toBeNil()
        fx.teardown()
    end)

    it('throttles repeated scans of the same spot', function()
        boot()
        join(1, walker(10.0, 10.0))
        fx.advance(200)
        Atlas.boost(10.0, 10.0)
        local first = Atlas.sampler.boostUntil[1]
        fx.state.gt = fx.state.gt + 100
        Atlas.boost(11.0, 11.0)
        expect(Atlas.sampler.boostUntil[1]).toBe(first)
        fx.teardown()
    end)
end)
