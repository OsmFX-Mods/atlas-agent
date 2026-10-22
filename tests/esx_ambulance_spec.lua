local fx = load_module('tests/fivem.lua')

local state -- state: the fake ESX world: live players and their isDead flags

local function boot(resources)
    state = { players = {}, dead = {} }
    local res = { es_extended = 'started', esx_ambulancejob = 'started' }
    for k, v in pairs(resources or {}) do res[k] = v end
    fx.boot({
        convars = { ['atlas:token'] = 'atl_live_x' }, resources = res,
        provided = { es_extended = { getSharedObject = function()
            return { GetPlayerFromId = function(src) return state.players[src] end }
        end } },
        load = { 'server/db.lua', 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua',
            'server/characters.lua', 'server/staff.lua', 'server/money.lua', 'server/adapters/esx_data.lua', 'server/adapters/esx.lua',
            'server/adapters/esx_death.lua', 'server/adapters/esx_ambulance.lua' },
    })
    fx.set('Player', function(src) return { state = { isDead = state.dead[src] } } end)
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

local function login(src)
    fx.addPlayer(src, { ped = { x = 10.0, y = 10.0, z = 30.0, h = 0.0 } })
    Atlas.ensurePlayer(src)
    state.players[src] = {
        source = src, identifier = 'char1:abc' .. src, variables = {}, job = { name = 'police', grade = 1 },
        getJob = function() return state.players[src].job end,
        getAccounts = function() return { money = 0, bank = 0 } end,
    }
    TriggerEvent('esx:playerLoaded', src, state.players[src], false)
end

--- Flip: ambulancejob sets the isDead state; the matching client event arrives with it, as it does on a real server.
local function flip(src, dead, signal)
    if signal then fx.net(signal, src, signal == 'esx:triggerServerCallback' and 'esx_ambulancejob:removeItemsAfterRPDeath' or {}) end
    state.dead[src] = dead
    fx.stateBag(src, 'isDead', dead)
    fx.advance(AtlasConfig.esx.deathSettleMs + 100)
end

describe('esx ambulancejob deaths', function()
    it('emits combat.death and player.state when the character dies', function()
        boot()
        login(4)
        flip(4, true, 'esx:onPlayerDeath')
        expect(events('combat.death')[1].data.state).toBe('dead')
        expect(events('player.state')[1].data).toEqual({ key = 'isdead', value = true })
        expect(Atlas.players[4].dead).toBe(true)
        fx.teardown()
    end)

    it('reports a revive when the state clears without a respawn', function()
        boot()
        login(4)
        flip(4, true, 'esx:onPlayerDeath')
        flip(4, false)
        expect(#events('medical.revive')).toBe(1)
        expect(#events('medical.respawn')).toBe(0)
        fx.teardown()
    end)

    it('reports a hospital respawn, not a revive, when the respawn callback came first', function()
        boot()
        login(4)
        flip(4, true, 'esx:onPlayerDeath')
        flip(4, false, 'esx:triggerServerCallback')
        expect(#events('medical.respawn')).toBe(1)
        expect(#events('medical.revive')).toBe(0)
        fx.teardown()
    end)

    it('does not report a death restored at login as a new one', function()
        boot()
        login(4)
        flip(4, true)
        expect(#events('combat.death')).toBe(0)
        expect(Atlas.players[4].down).toBe(true)
        flip(4, false)
        expect(#events('medical.revive')).toBe(1)
        fx.teardown()
    end)

    it('ignores a death event older than the signal time', function()
        boot()
        login(4)
        fx.net('esx:onPlayerDeath', 4, {})
        fx.advance(AtlasConfig.esx.deathSignalMs + 1000)
        flip(4, true)
        expect(#events('combat.death')).toBe(0)
        fx.teardown()
    end)

    it('reports one death when the state is set twice', function()
        boot()
        login(4)
        fx.net('esx:onPlayerDeath', 4, {})
        state.dead[4] = true
        fx.stateBag(4, 'isDead', true)
        fx.stateBag(4, 'isDead', true)
        fx.advance(AtlasConfig.esx.deathSettleMs + 100)
        expect(#events('combat.death')).toBe(1)
        fx.teardown()
    end)

    it('ignores players without a character', function()
        boot()
        fx.addPlayer(9, {})
        Atlas.ensurePlayer(9)
        flip(9, true, 'esx:onPlayerDeath')
        expect(#events('combat.death')).toBe(0)
        fx.teardown()
    end)

    it('leaves deaths to esx_death when it is running', function()
        boot({ esx_death = 'started' })
        login(4)
        flip(4, true, 'esx:onPlayerDeath')
        expect(#events('combat.death')).toBe(0)
        fx.teardown()
    end)
end)
