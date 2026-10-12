local fx = load_module('tests/fivem.lua')

local PISTOL = 453432689

local function boot(convars, resources)
    convars = convars or {}
    convars['atlas:token'] = 'atl_live_x'
    fx.boot({ convars = convars, resources = resources, load = { 'server/sampler.lua', 'server/client_reports.lua' } })
    fx.tick()
end

local function join(src, ped)
    fx.addPlayer(src, { ped = ped })
    return Atlas.ensurePlayer(src)
end

local function shooter(weapon)
    return { x = 110.0, y = 110.0, z = 30.0, h = 0.0, weapon = weapon or PISTOL }
end

local function report(ped, shots)
    local cx, cy = AtlasLib.shots.cell(ped.x, ped.y)
    return { window_s = 15, reports = { { weapon = PISTOL, cells = { { cx, cy, shots or 12 } } } } }
end

local function emitted(etype)
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

describe('client shot reports', function()
    it('accepts a plausible report and emits it with client trust', function()
        boot()
        local ped = shooter()
        join(1, ped)
        fx.net('atlas:c:shots', 1, report(ped, 12))
        local ev = emitted('combat.shots')[1]
        expect(ev ~= nil).toBe(true)
        expect(ev.trust).toBe('client')
        expect(ev.src).toBe(1)
        expect(ev.data.weapon).toBe(PISTOL)
        expect(ev.data.window_s).toBe(15)
        expect(ev.data.cells[1][3]).toBe(12)
        fx.teardown()
    end)

    it('accepts the weapon the server sees in hand even before the sampler has', function()
        boot()
        local ped = shooter(PISTOL)
        join(1, ped)
        fx.net('atlas:c:shots', 1, report(ped))
        expect(#emitted('combat.shots')).toBe(1)
        fx.teardown()
    end)

    it('accepts the weapon ox_inventory reports as equipped', function()
        boot(nil, { ox_inventory = 'started' })
        local ped = shooter(0)
        join(1, ped)
        fx.state.provided.ox_inventory = { GetCurrentWeapon = function() return { name = 'WEAPON_PISTOL' } end }
        local hash = AtlasLib.common.u32(fx.joaat('WEAPON_PISTOL'))
        local r = report(ped)
        r.reports[1].weapon = hash
        fx.net('atlas:c:shots', 1, r)
        expect(#emitted('combat.shots')).toBe(1)
        fx.teardown()
    end)

    it('rejects a weapon the server never saw and counts the drop', function()
        boot()
        local ped = shooter(0)
        join(1, ped)
        fx.net('atlas:c:shots', 1, report(ped))
        expect(#emitted('combat.shots')).toBe(0)
        expect(Atlas.drops.shots_weapon).toBe(1)
        fx.teardown()
    end)

    it('rejects cells far from where the server has the player', function()
        boot()
        local ped = shooter()
        join(1, ped)
        local far = report({ x = 2000.0, y = 2000.0 })
        fx.net('atlas:c:shots', 1, far)
        expect(#emitted('combat.shots')).toBe(0)
        expect(Atlas.drops.shots_position).toBe(1)
        fx.teardown()
    end)

    it('rejects reports from a dead player', function()
        boot()
        local ped = shooter()
        ped.hp = 0
        join(1, ped)
        fx.net('atlas:c:shots', 1, report(ped))
        expect(Atlas.drops.shots_dead).toBe(1)
        expect(#emitted('combat.shots')).toBe(0)
        fx.teardown()
    end)

    it('rejects a second report inside five seconds and accepts it afterwards', function()
        boot()
        local ped = shooter()
        join(1, ped)
        fx.net('atlas:c:shots', 1, report(ped))
        fx.advance(2000)
        fx.net('atlas:c:shots', 1, report(ped))
        expect(Atlas.drops.shots_rate).toBe(1)
        fx.advance(4000)
        fx.net('atlas:c:shots', 1, report(ped))
        expect(#emitted('combat.shots')).toBe(2)
        fx.teardown()
    end)

    it('reports rejections at most once a minute per player, with a running count', function()
        boot()
        local ped = shooter(0)
        join(1, ped)
        for _ = 1, 4 do
            fx.net('atlas:c:shots', 1, report(ped))
            fx.advance(6000)
        end
        local first = emitted('combat.shots_rejected')
        expect(#first).toBe(1)
        expect(first[1].data.reason).toBe('weapon')
        expect(first[1].data.count).toBe(1)
        expect(first[1].trust).toBe('derived')
        fx.advance(60000)
        fx.net('atlas:c:shots', 1, report(ped))
        local all = emitted('combat.shots_rejected')
        expect(#all).toBe(2)
        expect(all[2].data.count).toBe(4) -- Count: the three suppressed rejections plus the one that triggered the report
        expect(Atlas.drops.shots_weapon).toBe(5)
        fx.teardown()
    end)

    it('rejects malformed payloads without throwing', function()
        boot()
        join(1, shooter())
        fx.net('atlas:c:shots', 1, 'garbage')
        fx.advance(6000)
        fx.net('atlas:c:shots', 1, { window_s = 15, reports = 5 })
        expect(Atlas.drops.shots_malformed).toBe(2)
        fx.teardown()
    end)

    it('ignores players Atlas does not know and does nothing when switched off', function()
        boot()
        local ped = shooter()
        join(1, ped)
        fx.net('atlas:c:shots', 99, report(ped))
        expect(next(Atlas.drops)).toBeNil()
        fx.teardown()
        boot({ ['atlas:client_combat'] = 0 })
        join(1, ped)
        fx.net('atlas:c:shots', 1, report(ped))
        expect(#emitted('combat.shots')).toBe(0)
        expect(next(Atlas.drops)).toBeNil()
        expect(fx.state.players[1] ~= nil).toBe(true)
        fx.teardown()
    end)

    it('publishes the client_combat switch through GlobalState for clients', function()
        boot({ ['atlas:client_combat'] = 0 })
        expect(GlobalState.atlasClientCombat).toBe(false)
        fx.teardown()
        boot()
        expect(GlobalState.atlasClientCombat).toBe(true)
        fx.teardown()
    end)
end)
