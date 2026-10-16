local fx = load_module('tests/fivem.lua')

local state -- state: balances and groups the fake qbx_core serves

local function boot(over)
    state = { balances = { cash = 100, bank = 500 }, players = {}, jobs = { police = {} }, gangs = { ballas = {} } }
    local qbx = {
        GetCoreVersion = function() return '1.23.0' end,
        GetMoney = function(_, _, mtype)
            if state.moneyError then error('export failed') end
            return state.balances[mtype]
        end,
        GetPlayer = function(_, src) return state.players[src] end,
        GetJobs = function() return state.jobs end,
        GetGangs = function() return state.gangs end,
    }
    fx.boot({
        convars = { ['atlas:token'] = 'atl_live_x' },
        resources = { qbx_core = 'started', qbx_medical = 'started' },
        provided = { qbx_core = qbx },
        load = {
            'server/db.lua', 'server/sampler.lua', 'server/adapters/detect.lua', 'server/sources.lua',
            'server/framework.lua', 'server/characters.lua', 'server/money.lua', 'server/adapters/natives.lua',
            'server/adapters/qbox_data.lua', 'server/adapters/qbox.lua', 'server/adapters/qbx_medical.lua',
        },
    })
    state.db = { rows = {}, scalar = nil, scalarErr = nil }
    Atlas.db.available = function() return true end
    Atlas.db.query = function() return state.db.rows end
    Atlas.db.scalar = function() return state.db.scalar, state.db.scalarErr end
    if over then over() end
    fx.advance(200)
end

local function data(src, over)
    local pd = {
        source = src, citizenid = 'CHAR000' .. src, charinfo = { firstname = 'Ann', lastname = 'Lee' },
        job = { name = 'police', grade = { level = 2 }, onduty = true, payment = 75 },
        gang = { name = 'none' }, money = { cash = 100, bank = 500, crypto = 0 }, metadata = {},
        lastLoggedOut = 1790000000,
    }
    for k, v in pairs(over or {}) do pd[k] = v end
    return pd
end

local function login(src, over)
    fx.addPlayer(src, { ped = { x = 10.0, y = 10.0, z = 30.0, h = 0.0 } })
    Atlas.ensurePlayer(src)
    TriggerEvent('QBCore:Server:PlayerLoaded', { PlayerData = data(src, over) })
    return Atlas.players[src]
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

describe('qbox character lifecycle', function()
    it('loads identity and sends session.char_start with the actor details', function()
        boot()
        local p = login(4)
        local ev = events('session.char_start')[1]
        expect(ev.data.char).toBe('CHAR0004')
        expect(ev.data.char_name).toBe('Ann Lee')
        expect(ev.data.job).toBe('police')
        expect(ev.data.gang).toBeNil()
        expect(ev.data.is_new_char).toBe(false)
        expect(p.actor.job).toBe('police')
        expect(p.actor.grade).toBe(2)
        expect(p.actor.duty).toBe(true)
        expect(p.jobPayment).toBe(75)
        expect(Atlas.charToSrc.CHAR0004).toBe(4)
        expect(#events('character.create')).toBe(0)
        expect(#events('teleport.known')).toBe(1)
        fx.teardown()
    end)

    it('adds character.create for a character that was never saved', function()
        boot()
        login(4, { lastLoggedOut = false })
        state.players = nil
        fx.teardown()
        boot()
        fx.addPlayer(4, { ped = { x = 1.0, y = 1.0, z = 1.0 } })
        Atlas.ensurePlayer(4)
        local pd = data(4)
        pd.lastLoggedOut = nil
        TriggerEvent('QBCore:Server:PlayerLoaded', { PlayerData = pd })
        expect(events('character.create')[1].data.char).toBe('CHAR0004')
        expect(events('session.char_start')[1].data.is_new_char).toBe(true)
        fx.teardown()
    end)

    it('ignores a repeated load of the same character and ends the old one on a switch', function()
        boot()
        login(4)
        TriggerEvent('QBCore:Server:PlayerLoaded', { PlayerData = data(4) })
        expect(#events('session.char_start')).toBe(1)
        TriggerEvent('QBCore:Server:PlayerLoaded', { PlayerData = data(4, { citizenid = 'OTHER004' }) })
        local ends = events('session.char_end')
        expect(#ends).toBe(1)
        expect(ends[1].data.reason).toBe('switch')
        expect(ends[1].data.char).toBe('CHAR0004')
        expect(Atlas.charOf(4)).toBe('OTHER004')
        fx.teardown()
    end)

    it('rejects malformed load events', function()
        boot()
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        TriggerEvent('QBCore:Server:PlayerLoaded', 'junk')
        TriggerEvent('QBCore:Server:PlayerLoaded', { PlayerData = {} })
        TriggerEvent('QBCore:Server:PlayerLoaded', { PlayerData = { source = 4 } })
        expect(#events('session.char_start')).toBe(0)
        fx.teardown()
    end)

    it('ends the character on logout and clears the identity', function()
        boot()
        local p = login(4)
        TriggerEvent('QBCore:Server:OnPlayerUnload', 4)
        expect(events('session.char_end')[1].data.reason).toBe('logout')
        expect(p.char).toBeNil()
        expect(p.job).toBeNil()
        expect(Atlas.charToSrc.CHAR0004).toBeNil()
        TriggerEvent('QBCore:Server:OnPlayerUnload', 4)
        expect(#events('session.char_end')).toBe(1)
        fx.teardown()
    end)

    it('ends the character before the session when the player drops', function()
        boot()
        login(4)
        fx.net('playerJoining', 4, 'net:4')
        fx.net('playerDropped', 4, 'quit')
        local ev = events('session.char_end')[1]
        expect(ev.data.reason).toBe('drop')
        expect(#events('session.end')).toBe(1)
        fx.teardown()
    end)

    it('picks up characters that were already loaded when the agent started', function()
        boot(function()
            fx.addPlayer(6, { ped = { x = 1.0, y = 1.0, z = 1.0 } })
            state.players[6] = { PlayerData = data(6) }
        end)
        local ev = events('session.char_start')[1]
        expect(ev.data.char).toBe('CHAR0006')
        expect(ev.data.resumed).toBe(true)
        expect(#events('teleport.known')).toBe(0)
        fx.teardown()
    end)
end)

describe('qbox money', function()
    local function change(src, mtype, amount, action, reason)
        TriggerEvent('QBCore:Server:OnMoneyChange', src, mtype, amount, action, reason)
        local list = events('money.change')
        return list[#list]
    end

    it('records an add with the balance qbx reports afterwards and the paycheck amount', function()
        boot()
        login(4)
        state.balances.bank = 575
        local ev = change(4, 'bank', 75, 'add', 'paycheck')
        expect(ev.data.delta).toBe(75)
        expect(ev.data.balance_after).toBe(575)
        expect(ev.data.reason).toBe('paycheck')
        expect(ev.data.job_payment).toBe(75)
        expect(Atlas.players[4].money.bank).toBe(575)
        fx.teardown()
    end)

    it('records a removal as a negative delta', function()
        boot()
        login(4)
        state.balances.cash = 60
        local ev = change(4, 'cash', 40, 'remove', 'shop')
        expect(ev.data.delta).toBe(-40)
        expect(ev.data.amount).toBe(40)
        fx.teardown()
    end)

    it('works out the delta of a set from the last known balance', function()
        boot()
        login(4)
        state.balances.cash = 250
        expect(change(4, 'cash', 250, 'set', 'admin').data.delta).toBe(150)
        fx.teardown()
    end)

    it('leaves the delta empty for a set without a known balance', function()
        boot()
        login(4)
        state.balances.crypto = 5
        Atlas.players[4].money.crypto = nil
        expect(change(4, 'crypto', 5, 'set', 'admin').data.delta).toBeNil()
        fx.teardown()
    end)

    it('survives a failing balance read and a non-string reason', function()
        boot()
        login(4)
        state.moneyError = true
        local ev = change(4, 'cash', 10, 'add', { 1 })
        expect(ev.data.balance_after).toBeNil()
        expect(ev.data.reason).toBe('unknown')
        expect(ev.data.delta).toBe(10)
        fx.teardown()
    end)

    it('truncates long reasons and flags the selftest marker', function()
        boot()
        login(4)
        expect(#change(4, 'cash', 1, 'add', string.rep('r', 300)).data.reason).toBe(128)
        change(4, 'cash', 0, 'add', 'atlas_selftest')
        expect(Atlas.selftestMoneySeen).toBe(true)
        fx.teardown()
    end)

    it('exposes live balances of online characters for the snapshot', function()
        boot()
        login(4)
        fx.addPlayer(5, {})
        Atlas.ensurePlayer(5)
        local online = Atlas.onlineBalances()
        expect(online.CHAR0004.bank).toBe(500)
        expect(online.CHAR0005).toBeNil()
        fx.teardown()
    end)
end)

describe('qbox job, duty and gang', function()
    it('emits job.change for a real move and keeps the actor current', function()
        boot()
        local p = login(4)
        TriggerEvent('QBCore:Server:OnJobUpdate', 4, { name = 'ems', grade = { level = 1 }, onduty = true, payment = 90 })
        local ev = events('job.change')[1]
        expect(ev.data.from).toEqual({ job = 'police', grade = 2 })
        expect(ev.data.to).toEqual({ job = 'ems', grade = 1 })
        expect(p.actor.job).toBe('ems')
        expect(p.jobPayment).toBe(90)
        fx.teardown()
    end)

    it('does not emit job.change when only the job definition was edited', function()
        boot()
        login(4)
        TriggerEvent('QBCore:Server:OnJobUpdate', 4, { name = 'police', grade = { level = 2 }, onduty = true, payment = 120 })
        expect(#events('job.change')).toBe(0)
        expect(Atlas.players[4].jobPayment).toBe(120)
        fx.teardown()
    end)

    it('updates duty through the job event without a job.change', function()
        boot()
        local p = login(4)
        TriggerEvent('QBCore:Server:OnJobUpdate', 4, { name = 'police', grade = { level = 2 }, onduty = false })
        expect(p.duty).toBe(false)
        expect(p.actor.duty).toBe(false)
        expect(#events('job.change')).toBe(0)
        fx.teardown()
    end)

    it('emits duty.change once per change', function()
        boot()
        login(4)
        TriggerEvent('QBCore:Server:SetDuty', 4, false)
        TriggerEvent('QBCore:Server:SetDuty', 4, false)
        TriggerEvent('QBCore:Server:SetDuty', 4, true)
        local ev = events('duty.change')
        expect(#ev).toBe(2)
        expect(ev[1].data).toEqual({ job = 'police', on = false })
        fx.teardown()
    end)

    it('emits gang.change when joining and leaving a gang, and treats none as no gang', function()
        boot()
        login(4)
        TriggerEvent('QBCore:Server:OnGangUpdate', 4, { name = 'none' })
        TriggerEvent('QBCore:Server:OnGangUpdate', 4, { name = 'ballas' })
        TriggerEvent('QBCore:Server:OnGangUpdate', 4, { name = 'ballas' })
        TriggerEvent('QBCore:Server:OnGangUpdate', 4, { name = 'none' })
        local ev = events('gang.change')
        expect(#ev).toBe(2)
        expect(ev[1].data).toEqual({ to = 'ballas' })
        expect(ev[2].data).toEqual({ from = 'ballas' })
        fx.teardown()
    end)

    it('ignores job and gang events for players without a character', function()
        boot()
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        TriggerEvent('QBCore:Server:OnJobUpdate', 4, { name = 'ems', grade = { level = 1 } })
        TriggerEvent('QBCore:Server:OnGangUpdate', 4, { name = 'ballas' })
        TriggerEvent('QBCore:Server:SetDuty', 4, false)
        expect(Atlas.lastSeq()).toBe(0)
        fx.teardown()
    end)
end)

describe('qbox death and revive', function()
    local function meta(src, key, old, value)
        TriggerEvent('qbx_core:server:onSetMetaData', key, old, value, src)
    end

    it('emits one combat.death per down and the player.state change', function()
        boot()
        login(4)
        meta(4, 'isdead', false, true)
        meta(4, 'isdead', true, true)
        local deaths = events('combat.death')
        expect(#deaths).toBe(1)
        expect(deaths[1].data).toEqual({ state = 'dead', cause = 'unknown' })
        expect(events('player.state')[1].data).toEqual({ key = 'isdead', value = true })
        expect(Atlas.players[4].dead).toBe(true)
        fx.teardown()
    end)

    it('reports last stand then death as a single down', function()
        boot()
        login(4)
        meta(4, 'inlaststand', false, true)
        meta(4, 'isdead', false, true)
        local deaths = events('combat.death')
        expect(#deaths).toBe(1)
        expect(deaths[1].data.state).toBe('laststand')
        fx.teardown()
    end)

    it('ignores a lethal hit older than the configured window', function()
        boot()
        login(4); login(5)
        AtlasConfig.killWindowMs = 2000
        Atlas.lastLethal[4] = { src = 5, char = 'CHAR0005', weapon = 99, gt = GetGameTimer() - 3000 }
        meta(4, 'isdead', false, true)
        expect(events('combat.death')[1].data.cause).toBe('unknown')
        fx.teardown()
    end)

    it('names the killer when a lethal hit from another player came within ten seconds', function()
        boot()
        login(4); login(5)
        Atlas.lastLethal[4] = { src = 5, char = 'CHAR0005', weapon = 99, gt = GetGameTimer() }
        meta(4, 'isdead', false, true)
        local d = events('combat.death')[1].data
        expect(d.cause).toBe('player')
        expect(d.killer_char).toBe('CHAR0005')
        expect(d.killer_src).toBe(5)
        expect(d.weapon).toBe(99)
        expect(Atlas.lastLethal[4]).toBeNil()
        fx.teardown()
    end)

    it('does not blame a stale hit or the victim themself', function()
        boot()
        login(4); login(5)
        Atlas.lastLethal[4] = { src = 5, char = 'CHAR0005', weapon = 99, gt = GetGameTimer() - 11000 }
        meta(4, 'isdead', false, true)
        expect(events('combat.death')[1].data.cause).toBe('unknown')
        meta(4, 'isdead', true, false)
        Atlas.lastLethal[4] = { src = 4, char = 'CHAR0004', weapon = 99, gt = GetGameTimer() }
        meta(4, 'isdead', false, true)
        expect(events('combat.death')[2].data.cause).toBe('unknown')
        fx.teardown()
    end)

    it('emits medical.revive when the down state clears', function()
        boot()
        login(4)
        meta(4, 'isdead', false, true)
        meta(4, 'isdead', true, false)
        expect(#events('medical.revive')).toBe(1)
        expect(Atlas.players[4].down).toBe(false)
        fx.teardown()
    end)

    it('skips the revive after a hospital respawn announced itself', function()
        boot()
        login(4)
        meta(4, 'isdead', false, true)
        TriggerEvent('qbx_medical:server:playerRespawned', 4)
        meta(4, 'isdead', true, false)
        expect(#events('medical.revive')).toBe(0)
        expect(#events('medical.respawn')).toBe(1)
        fx.teardown()
    end)

    it('ignores keys it does not track and unchanged values', function()
        boot()
        login(4)
        meta(4, 'hunger', 10, 20)
        meta(4, 'ishandcuffed', false, false)
        expect(#events('player.state')).toBe(0)
        meta(4, 'injail', 0, 0)
        meta(4, 'injail', 0, 30)
        expect(#events('player.state')).toBe(1)
        fx.teardown()
    end)
end)

describe('qbox character deletion', function()
    local function setup()
        boot(function()
            fx.addPlayer(4, { identifiers = { 'license2:abc', 'license:def' } })
            state.db.rows = { { citizenid = 'CHAR0004', n = 'Ann Lee' }, { citizenid = 'CHAR0009', n = '' } }
        end)
        fx.net('playerJoining', 4, 'net:4')
        fx.advance(100)
    end

    it('emits character.delete once the row is gone from the database', function()
        setup()
        fx.net('qbx_core:server:deleteCharacter', 4, 'CHAR0004')
        fx.advance(3500)
        local ev = events('character.delete')
        expect(#ev).toBe(1)
        expect(ev[1].data).toEqual({ char = 'CHAR0004', char_name = 'Ann Lee' })
        fx.teardown()
    end)

    it('also listens on the ox_lib callback event', function()
        setup()
        fx.net('__ox_cb_qbx_core:server:deleteCharacter', 4, 'resource', 'key', 'CHAR0009')
        fx.advance(3500)
        local ev = events('character.delete')[1]
        expect(ev.data.char).toBe('CHAR0009')
        expect(ev.data.char_name).toBeNil()
        fx.teardown()
    end)

    it('emits nothing while the row still exists', function()
        setup()
        state.db.scalar = 1
        fx.net('qbx_core:server:deleteCharacter', 4, 'CHAR0004')
        fx.advance(3500)
        expect(#events('character.delete')).toBe(0)
        fx.teardown()
    end)

    it('emits nothing when the database check fails', function()
        setup()
        state.db.scalarErr = 'connection lost'
        fx.net('qbx_core:server:deleteCharacter', 4, 'CHAR0004')
        fx.advance(3500)
        expect(#events('character.delete')).toBe(0)
        fx.teardown()
    end)

    it('ignores ids the account does not own and malformed ids', function()
        setup()
        fx.net('qbx_core:server:deleteCharacter', 4, 'SOMEONE_ELSE')
        fx.net('qbx_core:server:deleteCharacter', 4, 12345)
        fx.net('qbx_core:server:deleteCharacter', 99, 'CHAR0004')
        fx.advance(3500)
        expect(#events('character.delete')).toBe(0)
        fx.teardown()
    end)

    it('still records the deletion when the player leaves during the check, without a player', function()
        setup()
        fx.net('qbx_core:server:deleteCharacter', 4, 'CHAR0004')
        fx.net('playerDropped', 4, 'quit')
        fx.advance(3500)
        local ev = events('character.delete')
        expect(#ev).toBe(1)
        expect(ev[1].src).toBeNil()
        fx.teardown()
    end)

    it('emits a deletion only once', function()
        setup()
        fx.net('qbx_core:server:deleteCharacter', 4, 'CHAR0004')
        fx.advance(3500)
        fx.net('qbx_core:server:deleteCharacter', 4, 'CHAR0004')
        fx.advance(3500)
        expect(#events('character.delete')).toBe(1)
        fx.teardown()
    end)

    it('runs one check for repeated requests inside the wait', function()
        setup()
        local checks, scalar = 0, Atlas.db.scalar
        Atlas.db.scalar = function(...) checks = checks + 1 return scalar(...) end
        for _ = 1, 5 do fx.net('qbx_core:server:deleteCharacter', 4, 'CHAR0004') end
        fx.advance(3500)
        expect(checks).toBe(1)
        expect(#events('character.delete')).toBe(1)
        fx.teardown()
    end)

    it('does not attribute the deletion to a different player who reused the id', function()
        setup()
        fx.net('qbx_core:server:deleteCharacter', 4, 'CHAR0004')
        fx.net('playerDropped', 4, 'quit')
        fx.addPlayer(4, { identifiers = { 'license2:other' } })
        Atlas.ensurePlayer(4)
        fx.advance(3500)
        local ev = events('character.delete')
        expect(#ev).toBe(1)
        expect(ev[1].src).toBeNil()
        fx.teardown()
    end)
end)

describe('qbox groups', function()
    it('lists job and gang names for account classification', function()
        boot()
        local jobs, gangs = Atlas.groups()
        expect(jobs.police).toBe(true)
        expect(gangs.ballas).toBe(true)
        fx.teardown()
    end)
end)
