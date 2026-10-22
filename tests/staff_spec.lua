local fx = load_module('tests/fivem.lua')

local groups -- groups: ESX groups by server id, read through the fake state bag

local function boot(resources, provided)
    groups = {}
    fx.boot({
        convars = { ['atlas:token'] = 'atl_live_x' }, resources = resources or {}, provided = provided or {},
        load = { 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua', 'server/characters.lua', 'server/staff.lua', 'server/money.lua' },
    })
    fx.set('Player', function(src) return { state = { group = groups[src] } } end)
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

local function join(src, aces)
    fx.addPlayer(src, { aces = aces })
    Atlas.runJoin(Atlas.ensurePlayer(src))
end

describe('staff ranks', function()
    it('sends the highest ACE rank on join and nothing for a player without one', function()
        boot()
        join(4, { mod = true, admin = true })
        join(5, {})
        join(6, { command = true })
        local ev = events('player.staff')
        expect(#ev).toBe(2)
        expect(ev[1].data.role).toBe('admin')
        expect(ev[2].data.role).toBe('admin')
        fx.teardown()
    end)

    it('sends a change only, including a rank taken away', function()
        boot()
        join(4, { mod = true })
        Atlas.staff.check(4)
        fx.state.players[4].aces = { god = true }
        fx.net('QBCore:Server:OnPermissionUpdate', nil, 4)
        fx.state.players[4].aces = {}
        Atlas.staff.check(4)
        local ev = events('player.staff')
        expect(#ev).toBe(3)
        expect(ev[1].data.role).toBe('mod')
        expect(ev[2].data.role).toBe('god')
        expect(ev[3].data.role).toBeNil()
        fx.teardown()
    end)

    it('prefers the rank the framework keeps', function()
        boot()
        Atlas.framework = { staffRole = function(src) return src == 4 and 'SuperAdmin' or nil end }
        join(4, {})
        join(5, { mod = true })
        local ev = events('player.staff')
        expect(ev[1].data.role).toBe('superadmin')
        expect(ev[2].data.role).toBe('mod')
        fx.teardown()
    end)
end)
