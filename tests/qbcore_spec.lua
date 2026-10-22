local fx = load_module('tests/fivem.lua')

local state -- state: the fake qb-core world: live players and shared tables

local function boot(over, resources)
    state = { players = {}, jobs = { police = {}, ambulance = {} }, gangs = { none = {}, ballas = {} }, objectError = false, objectCalls = 0 }
    local core = {
        Functions = { GetPlayer = function(src) return state.players[src] end },
        Shared = {
            Jobs = state.jobs, Gangs = state.gangs,
            Vehicles = { adder = { name = 'Adder', brand = 'Truffade', price = 280000, category = 'super', shop = 'pdm' } },
        },
    }
    local res = { ['qb-core'] = 'started', ['qb-ambulancejob'] = 'started' }
    for k, v in pairs(resources or {}) do res[k] = v end
    fx.boot({
        convars = { ['atlas:token'] = 'atl_live_x' },
        resources = res,
        provided = { ['qb-core'] = {
            GetCoreObject = function()
                state.objectCalls = state.objectCalls + 1
                if state.objectError then error('not ready') end
                return core
            end,
        } },
        files = {
            ['qb-ambulancejob/config.lua'] = [[Config = {}
                Config.BillCost = 2000
                Config.Locations = { ['hospital'] = { { ['name'] = Lang:t('info.pb_hospital'), ['location'] = vector3(308.0, -595.0, 43.0) } } }]],
            ['qb-ambulancejob/locales/en.lua'] = [[local Translations = { info = { pb_hospital = 'Pillbox Hospital' } }
                Lang = Lang or Locale:new({ phrases = Translations, warnOnMissing = true })]],
        },
        load = {
            'server/db.lua', 'server/sampler.lua', 'server/adapters/detect.lua', 'server/sources.lua',
            'server/framework.lua', 'server/characters.lua', 'server/staff.lua', 'server/money.lua', 'server/adapters/natives.lua',
            'server/adapters/qb_common.lua', 'server/adapters/qbox_data.lua', 'server/adapters/qbox.lua',
            'server/adapters/qbcore_data.lua', 'server/adapters/qbcore.lua', 'server/adapters/qb_ambulancejob.lua',
        },
    })
    state.db = { rows = {}, scalar = nil, scalarErr = nil }
    Atlas.db.available = function() return true end
    Atlas.db.query = function() return state.db.rows end
    Atlas.db.scalar = function() return state.db.scalar, state.db.scalarErr end
    if over then over() end
    fx.advance(200)
end

local function playerData(src, over)
    local pd = {
        source = src, id = src, citizenid = 'CID' .. src, license = 'license:lic' .. src, last_updated = 1790000000000,
        charinfo = { firstname = 'Ann', lastname = 'Lee' },
        job = { name = 'police', onduty = true, grade = { level = 2, payment = 150 } },
        gang = { name = 'none', grade = { level = 0 } },
        money = { cash = 100, bank = 500, crypto = 0 },
        metadata = { isdead = false, inlaststand = false, ishandcuffed = false, injail = 0 },
    }
    for k, v in pairs(over or {}) do pd[k] = v end
    return pd
end

local function newPlayer(src, over)
    local player = { PlayerData = playerData(src, over) }
    player.Functions = {
        SetMoney = function(mtype, amount, reason)
            player.PlayerData.money[mtype] = amount
            TriggerEvent('QBCore:Server:OnPlayerUpdated', src, 'money', player.PlayerData.money)
            TriggerEvent('QBCore:Server:OnMoneyChange', src, mtype, amount, 'set', reason)
        end,
    }
    state.players[src] = player
    return player
end

local function login(src, over)
    fx.addPlayer(src, { ped = { x = 10.0, y = 10.0, z = 30.0, h = 0.0 } })
    Atlas.ensurePlayer(src)
    local player = newPlayer(src, over)
    TriggerEvent('QBCore:Server:PlayerLoaded', player)
    return player, Atlas.players[src]
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

describe('qbcore adapter attach', function()
    it('registers as the framework when qb-core is started', function()
        boot()
        expect(Atlas.adapterActive('qbcore')).toBe(true)
        expect(Atlas.framework.name).toBe('qbcore')
        expect(Atlas.charFallback).toBe(false)
        fx.teardown()
    end)

    it('retries while qb-core is not ready', function()
        boot(function() state.objectError = true end)
        expect(Atlas.adapterActive('qbcore')).toBe(false)
        state.objectError = false
        fx.advance(2000)
        expect(Atlas.adapterActive('qbcore')).toBe(true)
        fx.teardown()
    end)

    it('stays off on Qbox, where qbx_core also answers to qb-core', function()
        boot(nil, { qbx_core = 'started' })
        expect(Atlas.adapterActive('qbcore')).toBe(false)
        for _, def in ipairs(Atlas.adapterList()) do
            if def.name == 'qbcore' then expect(def.displaced()).toBe('qbx_core') end
        end
        fx.teardown()
    end)

    it('caches the core object instead of copying it on every call', function()
        boot()
        local calls = state.objectCalls
        login(4)
        Atlas.groups()
        Atlas.groups()
        expect(state.objectCalls).toBe(calls)
        TriggerEvent('QBCore:Server:UpdateObject')
        Atlas.groups()
        expect(state.objectCalls).toBe(calls + 1)
        fx.teardown()
    end)
end)

describe('qbcore character lifecycle', function()
    it('loads identity, job and money and sends session.char_start', function()
        boot()
        local _, p = login(4)
        local ev = events('session.char_start')[1]
        expect(ev.data.char).toBe('CID4')
        expect(ev.data.char_name).toBe('Ann Lee')
        expect(ev.data.job).toBe('police')
        expect(ev.data.gang).toBeNil()
        expect(ev.data.is_new_char).toBe(false)
        expect(p.grade).toBe(2)
        expect(p.duty).toBe(true)
        expect(p.jobPayment).toBe(150)
        expect(p.money).toEqual({ cash = 100, bank = 500, crypto = 0 })
        expect(#events('character.create')).toBe(0)
        fx.teardown()
    end)

    it('adds character.create for a character made this session, which has no row id yet', function()
        boot()
        local player = newPlayer(4)
        player.PlayerData.id, player.PlayerData.last_updated = nil, nil
        fx.addPlayer(4, {})
        Atlas.ensurePlayer(4)
        TriggerEvent('QBCore:Server:PlayerLoaded', player)
        expect(#events('character.create')).toBe(1)
        expect(events('session.char_start')[1].data.is_new_char).toBe(true)
        fx.teardown()
    end)

    it('ends the character on logout and on a drop with the right reason', function()
        boot()
        login(4)
        TriggerEvent('QBCore:Server:OnPlayerUnload', 4)
        login(5)
        TriggerEvent('QBCore:Server:PlayerDropped', 5)
        TriggerEvent('QBCore:Server:OnPlayerUnload', 5)
        local ends = events('session.char_end')
        expect(ends[1].data.reason).toBe('logout')
        expect(ends[2].data.reason).toBe('drop')
        expect(Atlas.players[4].char).toBeNil()
        fx.teardown()
    end)

    it('ignores a repeated load and ends the old character on a switch', function()
        boot()
        local player = login(4)
        TriggerEvent('QBCore:Server:PlayerLoaded', player)
        expect(#events('session.char_start')).toBe(1)
        local other = newPlayer(4, { citizenid = 'CID40' })
        TriggerEvent('QBCore:Server:PlayerLoaded', other)
        expect(events('session.char_end')[1].data.reason).toBe('switch')
        expect(Atlas.players[4].char).toBe('CID40')
        fx.teardown()
    end)

    it('picks up characters already loaded when the agent starts, without a spawn', function()
        boot(function()
            fx.addPlayer(7, {})
            newPlayer(7)
        end)
        fx.advance(100)
        local ev = events('session.char_start')[1]
        expect(ev.data.char).toBe('CID7')
        expect(ev.data.resumed).toBe(true)
        expect(#events('teleport.known')).toBe(0)
        fx.teardown()
    end)
end)

describe('qbcore money', function()
    it('takes the balance from the money table qb-core 1.3.0 sends first', function()
        boot()
        login(4)
        TriggerEvent('QBCore:Server:OnPlayerUpdated', 4, 'money', { cash = 100, bank = 650, crypto = 0 })
        TriggerEvent('QBCore:Server:OnMoneyChange', 4, 'bank', 150, 'add', 'paycheck')
        local ev = events('money.change')[1]
        expect(ev.data).toEqual({ mtype = 'bank', action = 'add', amount = 150, delta = 150, balance_after = 650, reason = 'paycheck', job_payment = 150 })
        expect(Atlas.players[4].money.bank).toBe(650)
        fx.teardown()
    end)

    it('takes the balance from the PlayerData older releases send first', function()
        boot()
        local player = login(4)
        player.PlayerData.money.cash = 60
        TriggerEvent('QBCore:Player:SetPlayerData', player.PlayerData)
        TriggerEvent('QBCore:Server:OnMoneyChange', 4, 'cash', 40, 'remove', 'shop')
        local ev = events('money.change')[1]
        expect(ev.data.delta).toBe(-40)
        expect(ev.data.balance_after).toBe(60)
        fx.teardown()
    end)

    it('works the balance out from the last known one when no money table came in the same tick', function()
        boot()
        login(4)
        TriggerEvent('QBCore:Server:OnPlayerUpdated', 4, 'money', { cash = 999, bank = 999, crypto = 0 })
        fx.advance(100)
        TriggerEvent('QBCore:Server:OnMoneyChange', 4, 'bank', 50, 'add')
        local ev = events('money.change')[1]
        expect(ev.data.balance_after).toBe(550)
        expect(ev.data.reason).toBe('unknown')
        fx.teardown()
    end)

    it('measures a set from the last known balance', function()
        boot()
        login(4)
        TriggerEvent('QBCore:Server:OnMoneyChange', 4, 'bank', 200, 'set', 'Admin set')
        local ev = events('money.change')[1]
        expect(ev.data.delta).toBe(-300)
        expect(ev.data.balance_after).toBe(200)
        fx.teardown()
    end)

    it('maps money types through the config and keeps unknown ones by name', function()
        boot()
        login(4, { money = { cash = 1, bank = 2, crypto = 0, blackmoney = 30 } })
        expect(Atlas.players[4].money.black_money).toBe(30)
        TriggerEvent('QBCore:Server:OnMoneyChange', 4, 'blackmoney', 5, 'add', 'drugs')
        TriggerEvent('QBCore:Server:OnMoneyChange', 4, 'tokens', 5, 'add', 'arcade')
        local evs = events('money.change')
        expect(evs[1].data.mtype).toBe('black_money')
        expect(evs[1].data.balance_after).toBe(35)
        expect(evs[2].data.mtype).toBe('tokens')
        expect(evs[2].data.balance_after).toBeNil()
        fx.teardown()
    end)

    it('reaches the money hook in the selftest without changing the balance', function()
        boot()
        local player = login(4)
        local ok = Atlas.framework.selftestMoney(4)
        expect(ok).toBe(true)
        expect(Atlas.selftestMoneySeen).toBe(true)
        expect(player.PlayerData.money.bank).toBe(500)
        fx.teardown()
    end)
end)

describe('qbcore job, duty and gang', function()
    it('emits job.change for a new job and duty.change for a duty switch of the same job', function()
        boot()
        login(4)
        TriggerEvent('QBCore:Server:OnJobUpdate', 4, { name = 'ambulance', onduty = true, grade = { level = 0, payment = 50 } })
        TriggerEvent('QBCore:Server:OnJobUpdate', 4, { name = 'ambulance', onduty = false, grade = { level = 0, payment = 50 } })
        TriggerEvent('QBCore:Server:SetDuty', 4, true)
        local jobs = events('job.change')
        expect(#jobs).toBe(1)
        expect(jobs[1].data).toEqual({ from = { job = 'police', grade = 2 }, to = { job = 'ambulance', grade = 0 } })
        local duty = events('duty.change')
        expect(#duty).toBe(2)
        expect(duty[1].data).toEqual({ job = 'ambulance', on = false })
        expect(duty[2].data).toEqual({ job = 'ambulance', on = true })
        expect(Atlas.players[4].jobPayment).toBe(50)
        fx.teardown()
    end)

    it('emits gang.change and treats none as no gang', function()
        boot()
        login(4)
        TriggerEvent('QBCore:Server:OnGangUpdate', 4, { name = 'ballas', grade = { level = 1 } })
        TriggerEvent('QBCore:Server:OnGangUpdate', 4, { name = 'none', grade = { level = 0 } })
        local gangs = events('gang.change')
        expect(gangs[1].data).toEqual({ to = 'ballas' })
        expect(gangs[2].data).toEqual({ from = 'ballas' })
        fx.teardown()
    end)
end)

describe('qbcore death and revive', function()
    local function meta(src, md)
        TriggerEvent('QBCore:Server:OnPlayerUpdated', src, 'metadata', md)
    end

    it('reports a death from the metadata qb-core 1.3.0 sends, and the revive when it clears', function()
        boot()
        login(4)
        meta(4, { isdead = true, inlaststand = false, injail = 0 })
        meta(4, { isdead = true, inlaststand = false, injail = 0, hunger = 50 })
        expect(#events('combat.death')).toBe(1)
        expect(events('player.state')[1].data).toEqual({ key = 'isdead', value = true })
        meta(4, { isdead = false, inlaststand = false, injail = 0 })
        expect(#events('medical.revive')).toBe(1)
        fx.teardown()
    end)

    it('reads the same flags from the PlayerData older releases send', function()
        boot()
        local player = login(4)
        player.PlayerData.metadata.inlaststand = true
        TriggerEvent('QBCore:Player:SetPlayerData', player.PlayerData)
        player.PlayerData.metadata.isdead = true
        TriggerEvent('QBCore:Player:SetPlayerData', player.PlayerData)
        local deaths = events('combat.death')
        expect(#deaths).toBe(1)
        expect(deaths[1].data.state).toBe('laststand')
        fx.teardown()
    end)

    it('reports jail as a number of months', function()
        boot()
        login(4)
        meta(4, { injail = 5 })
        meta(4, { injail = 5 })
        local st = events('player.state')
        expect(#st).toBe(1)
        expect(st[1].data).toEqual({ key = 'injail', value = 5 })
        fx.teardown()
    end)

    it('counts a hospital respawn as a respawn, not a revive, and only for a character that is down', function()
        boot()
        login(4)
        fx.net('hospital:server:RespawnAtHospital', 4, 1)
        expect(#events('medical.respawn')).toBe(0)
        meta(4, { isdead = true })
        fx.net('hospital:server:RespawnAtHospital', 4, 1)
        meta(4, { isdead = false })
        expect(#events('medical.respawn')).toBe(1)
        expect(#events('medical.revive')).toBe(0)
        fx.teardown()
    end)

    it('sends a hospital check-in with the hospital name from the locale and the bill', function()
        boot()
        login(4)
        fx.net('hospital:server:SendToBed', 4, 2, true, 1)
        expect(events('medical.checkin')[1].data).toEqual({ hospital = 'Pillbox Hospital', cost = 2000 })
        fx.teardown()
    end)
end)

describe('qbcore character deletion', function()
    local function setup()
        boot(function()
            fx.addPlayer(4, { identifiers = { 'license:lic4' } })
            state.db.rows = { { citizenid = 'CID4', n = 'Ann Lee' }, { citizenid = 'CID9', n = 'Bo Ray' } }
        end)
        fx.net('playerJoining', 4, 'net:4')
        fx.advance(100)
    end

    local function log(title, msg)
        TriggerEvent('qb-log:server:CreateLog', 'joinleave', title, 'red', msg)
        fx.advance(100)
    end

    it('emits character.delete from qb-core\'s deletion log once the row is gone', function()
        setup()
        log('Character Deleted', '**Player4** license:lic4 deleted **CID9**..')
        local ev = events('character.delete')
        expect(#ev).toBe(1)
        expect(ev[1].data).toEqual({ char = 'CID9', char_name = 'Bo Ray' })
        expect(ev[1].src).toBe(4)
        fx.teardown()
    end)

    it('also takes a forced deletion of a character no online player owns', function()
        setup()
        log('Character Force Deleted', 'Character **ZZZ1** got deleted')
        local ev = events('character.delete')[1]
        expect(ev.data).toEqual({ char = 'ZZZ1' })
        expect(ev.src).toBeNil()
        fx.teardown()
    end)

    it('emits nothing while the row exists, after a database error, or for other log lines', function()
        setup()
        state.db.scalar = 1
        log('Character Deleted', '**Player4** license:lic4 deleted **CID9**..')
        state.db.scalar, state.db.scalarErr = nil, 'connection lost'
        log('Character Deleted', '**Player4** license:lic4 deleted **CID9**..')
        state.db.scalarErr = nil
        log('Dropped', '**Player4** left **CID9**')
        TriggerEvent('qb-log:server:CreateLog', 'playermoney', 'Character Deleted', 'red', '**CID9**')
        fx.advance(100)
        expect(#events('character.delete')).toBe(0)
        fx.teardown()
    end)

    it('ignores the log line when a client sends it', function()
        setup()
        fx.net('qb-log:server:CreateLog', 4, 'joinleave', 'Character Deleted', 'red', '**x** deleted **CID4**..')
        fx.advance(100)
        expect(#events('character.delete')).toBe(0)
        fx.teardown()
    end)
end)
