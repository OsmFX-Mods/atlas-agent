local fx = load_module('tests/fivem.lua')

local function boot()
    fx.boot({
        convars = { ['atlas:token'] = 'atl_live_x' },
        load = { 'server/adapters/detect.lua', 'server/sources.lua', 'server/framework.lua', 'server/characters.lua', 'server/staff.lua', 'server/money.lua' },
    })
    fx.addPlayer(4, { ped = { x = 10.0, y = 10.0, z = 30.0, h = 0.0 } })
    Atlas.ensurePlayer(4)
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

local C
local function load(over)
    C = Atlas.characters
    local c = { char = 'C1', name = 'Ann Lee', job = 'police', grade = 2, duty = true, gang = 'ballas', jobPayment = 75,
        money = { cash = 10, bank = 20 } }
    for k, v in pairs(over or {}) do c[k] = v end
    return C.load(4, c)
end

describe('characters load', function()
    it('sets identity and sends session.char_start and a spawn teleport', function()
        boot()
        local p = load()
        expect(p.char).toBe('C1')
        expect(p.actor.job).toBe('police')
        expect(p.actor.gang).toBe('ballas')
        expect(p.jobPayment).toBe(75)
        expect(p.money).toEqual({ cash = 10, bank = 20 })
        local ev = events('session.char_start')[1]
        expect(ev.data.char_name).toBe('Ann Lee')
        expect(ev.data.is_new_char).toBe(false)
        expect(ev.data.resumed).toBeNil()
        expect(events('teleport.known')[1].data.reason).toBe('spawn')
        expect(#events('character.create')).toBe(0)
        fx.teardown()
    end)

    it('sends character.create only for a new character that was not resumed', function()
        boot()
        load({ isNew = true })
        expect(#events('character.create')).toBe(1)
        expect(events('session.char_start')[1].data.is_new_char).toBe(true)
        fx.teardown()
    end)

    it('marks a resumed character and sends no spawn', function()
        boot()
        load({ isNew = true, resumed = true })
        local ev = events('session.char_start')[1]
        expect(ev.data.resumed).toBe(true)
        expect(ev.data.is_new_char).toBe(false)
        expect(#events('character.create')).toBe(0)
        expect(#events('teleport.known')).toBe(0)
        fx.teardown()
    end)

    it('starts a dead character as already down', function()
        boot()
        local p = load({ dead = true })
        expect(p.dead).toBe(true)
        expect(p.down).toBe(true)
        fx.teardown()
    end)

    it('ignores a load without a character id', function()
        boot()
        expect(load({ char = false })).toBeNil()
        expect(#events('session.char_start')).toBe(0)
        fx.teardown()
    end)
end)

describe('characters unload', function()
    it('sends session.char_end with the reason and clears the identity', function()
        boot()
        local p = load()
        C.unload(p, 'logout')
        local ev = events('session.char_end')[1]
        expect(ev.data.reason).toBe('logout')
        expect(ev.data.char).toBe('C1')
        expect(p.char).toBeNil()
        expect(p.job).toBeNil()
        expect(p.money).toEqual({})
        fx.teardown()
    end)

    it('does nothing for a player without a character', function()
        boot()
        C = Atlas.characters
        C.unload(Atlas.players[4], 'drop')
        expect(#events('session.char_end')).toBe(0)
        fx.teardown()
    end)

    it('ends the character when the player drops', function()
        boot()
        load()
        Atlas.runDrop(Atlas.players[4], 'quit')
        expect(events('session.char_end')[1].data.reason).toBe('drop')
        fx.teardown()
    end)

    it('sends held money changes before the character ends', function()
        boot()
        local p = load()
        local sent = {}
        Atlas.money.onFlush(function(src) sent[#sent + 1] = src end)
        C.unload(p, 'logout')
        expect(sent).toEqual({ 4 })
        fx.teardown()
    end)
end)

describe('characters job, duty and gang', function()
    it('emits job.change for a real move and updates the actor', function()
        boot()
        local p = load()
        C.setJob(4, 'ems', 1, true, 90)
        local ev = events('job.change')[1]
        expect(ev.data).toEqual({ from = { job = 'police', grade = 2 }, to = { job = 'ems', grade = 1 } })
        expect(p.actor.job).toBe('ems')
        expect(p.jobPayment).toBe(90)
        fx.teardown()
    end)

    it('only refreshes pay when the job is the same', function()
        boot()
        local p = load()
        C.setJob(4, 'police', 2, true, 120)
        expect(#events('job.change')).toBe(0)
        expect(p.jobPayment).toBe(120)
        fx.teardown()
    end)

    it('keeps duty when the caller does not say', function()
        boot()
        local p = load()
        C.setJob(4, 'ems', 0, nil)
        expect(p.duty).toBe(true)
        fx.teardown()
    end)

    it('emits duty.change once per change', function()
        boot()
        local p = load()
        C.setDuty(4, false)
        C.setDuty(4, false)
        local ev = events('duty.change')
        expect(#ev).toBe(1)
        expect(ev[1].data).toEqual({ job = 'police', on = false })
        expect(p.actor.duty).toBe(false)
        fx.teardown()
    end)

    it('emits gang.change and treats nil as no gang', function()
        boot()
        local p = load()
        C.setGang(4, nil)
        C.setGang(4, nil)
        local ev = events('gang.change')
        expect(#ev).toBe(1)
        expect(ev[1].data.from).toBe('ballas')
        expect(ev[1].data.to).toBeNil()
        expect(p.gang).toBeNil()
        fx.teardown()
    end)

    it('ignores changes for a player without a character', function()
        boot()
        C = Atlas.characters
        C.setJob(4, 'ems', 1)
        C.setDuty(4, true)
        C.setGang(4, 'x')
        expect(#events('job.change') + #events('duty.change') + #events('gang.change')).toBe(0)
        fx.teardown()
    end)
end)

describe('characters medical state', function()
    it('emits one combat.death per down and a revive when the character is up again', function()
        boot()
        load()
        C.markDown(4, 'dead')
        C.markDown(4, 'laststand')
        local deaths = events('combat.death')
        expect(#deaths).toBe(1)
        expect(deaths[1].data.state).toBe('dead')
        expect(deaths[1].data.cause).toBe('unknown')
        C.markUp(4)
        expect(#events('medical.revive')).toBe(1)
        C.markUp(4)
        expect(#events('medical.revive')).toBe(1)
        fx.teardown()
    end)

    it('names the killer when another player hit the character shortly before', function()
        boot()
        load()
        fx.state.gt = 20000
        Atlas.lastLethal[4] = { gt = 15000, src = 9, char = 'KILLER', weapon = 123 }
        C.markDown(4, 'dead')
        local data = events('combat.death')[1].data
        expect(data.cause).toBe('player')
        expect(data.killer_char).toBe('KILLER')
        expect(data.weapon).toBe(123)
        expect(Atlas.lastLethal[4]).toBeNil()
        fx.teardown()
    end)

    it('ignores an old or own hit', function()
        boot()
        load()
        fx.state.gt = 40000
        Atlas.lastLethal[4] = { gt = 15000, src = 9, char = 'KILLER', weapon = 123 }
        C.markDown(4, 'dead')
        expect(events('combat.death')[1].data.cause).toBe('unknown')
        fx.teardown()
    end)

    it('marks a restored character down without a death event', function()
        boot()
        local p = load()
        C.markDown(4, 'dead', true)
        expect(p.down).toBe(true)
        expect(#events('combat.death')).toBe(0)
        C.markUp(4)
        expect(#events('medical.revive')).toBe(1)
        fx.teardown()
    end)

    it('does not report a revive after a respawn', function()
        boot()
        load()
        C.markDown(4, 'dead')
        C.respawn(4)
        C.markUp(4)
        expect(#events('medical.respawn')).toBe(1)
        expect(events('teleport.known')[2].data.reason).toBe('respawn')
        expect(#events('medical.revive')).toBe(0)
        fx.teardown()
    end)
end)
